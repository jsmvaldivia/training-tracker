//! HTTP integration tests for POST /pursuits and GET /pursuits/{id}.
//!
//! These tests spawn a real HTTP server in a background thread with a unique
//! data.json file on a unique port, make real HTTP requests using std.http.Client,
//! parse JSON responses, and verify persistence by making subsequent GET requests.
//!
//! Each test case:
//! 1. Spawns server in background thread with unique data.json in /tmp
//! 2. Makes HTTP requests via std.http.Client
//! 3. Verifies response status, headers, and JSON body
//! 4. Tests round-trip persistence where appropriate
//! 5. Cleans up server thread and temp file

const std = @import("std");
const testing = std.testing;
const json = std.json;
const net = std.Io.net;

const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");

const json_content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };

const ServerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,
    port: u16,
    data_path: []const u8,
    server: net.Server,
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, port: u16) !*ServerContext {
        const ctx = try allocator.create(ServerContext);
        errdefer allocator.destroy(ctx);

        var store = try store_mod.Store.init(allocator, io, data_path);
        errdefer store.deinit();

        const address = try net.IpAddress.parse("127.0.0.1", port);
        const server = try address.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);

        ctx.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .port = port,
            .data_path = data_path,
            .server = server,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        return ctx;
    }

    fn deinit(self: *ServerContext) void {
        self.should_stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        self.server.deinit(self.io);
        self.store.deinit();
        std.Io.Dir.cwd().deleteFile(self.io, self.data_path) catch {};
        self.allocator.destroy(self);
    }

    fn run(self: *ServerContext) void {
        while (!self.should_stop.load(.monotonic)) {
            // Use a timeout-based accept to check should_stop periodically.
            const stream = self.server.accept(self.io) catch continue;
            self.handleConnection(stream) catch {};
        }
    }

    fn handleConnection(self: *ServerContext, stream: net.Stream) !void {
        defer stream.close(self.io);

        var recv_buf: [64 * 1024]u8 = undefined;
        var send_buf: [64 * 1024]u8 = undefined;
        var stream_reader = stream.reader(self.io, &recv_buf);
        var stream_writer = stream.writer(self.io, &send_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        const method = request.head.method;
        var target_buf: [8 * 1024]u8 = undefined;
        const tlen = @min(request.head.target.len, target_buf.len);
        @memcpy(target_buf[0..tlen], request.head.target[0..tlen]);
        const target = target_buf[0..tlen];

        var body_buf: [1024 * 1024]u8 = undefined;
        const body = readBody(&request, &body_buf);

        if (try pursuits.handle(self.allocator, &self.store, method, target, body)) |resp| {
            defer if (resp.body.len > 0) self.allocator.free(resp.body);
            try request.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = &.{json_content_type},
                .keep_alive = false,
            });
            return;
        }

        if (method == .GET and std.mem.eql(u8, stripQuery(target), "/health")) {
            try request.respond("{\"status\":\"ok\"}", .{
                .status = .ok,
                .extra_headers = &.{json_content_type},
                .keep_alive = false,
            });
            return;
        }

        try request.respond("{\"status\":404,\"message\":\"Not found\"}", .{
            .status = .not_found,
            .extra_headers = &.{json_content_type},
            .keep_alive = false,
        });
    }

    fn readBody(request: *std.http.Server.Request, buf: []u8) []const u8 {
        if (!request.head.method.requestHasBody()) return "";
        const reader = request.readerExpectContinue(&.{}) catch return "";
        const n = reader.readSliceShort(buf) catch return "";
        return buf[0..n];
    }

    fn stripQuery(target: []const u8) []const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
        return target[0..q];
    }
};

const TestServer = struct {
    ctx: *ServerContext,
    port: u16,
    data_path: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn spawn(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, port: u16) !TestServer {
        const ctx = try ServerContext.init(allocator, io, data_path, port);
        errdefer ctx.deinit();

        const thread = try std.Thread.spawn(.{}, ServerContext.run, .{ctx});
        ctx.thread = thread;

        // Give server time to bind the port by trying to connect.
        var retries: usize = 0;
        while (retries < 10) : (retries += 1) {
            var client: std.http.Client = .{ .allocator = allocator, .io = io };
            defer client.deinit();

            const uri_str = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/health", .{port});
            defer allocator.free(uri_str);

            var req = client.request(.GET, try std.Uri.parse(uri_str), .{}) catch {
                // Server not ready yet — yield ~10ms before retrying.
                io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                continue;
            };
            defer req.deinit();

            req.sendBodiless() catch continue;
            var redirect_buf: [1024]u8 = undefined;
            _ = req.receiveHead(&redirect_buf) catch continue;
            break; // Server is up
        }

        return .{
            .ctx = ctx,
            .port = port,
            .data_path = data_path,
            .allocator = allocator,
            .io = io,
        };
    }

    fn deinit(self: *TestServer) void {
        self.ctx.deinit();
    }

    fn request(
        self: *TestServer,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        body: []const u8,
    ) !HttpResponse {
        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();

        const uri_str = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
        defer allocator.free(uri_str);

        var req = try client.request(method, try std.Uri.parse(uri_str), .{});
        defer req.deinit();

        if (body.len > 0) {
            try req.sendBodyComplete(@constCast(body));
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var body_buf: [1024 * 1024]u8 = undefined;
        const reader = response.reader(&body_buf);
        const response_body = try reader.readAlloc(allocator, 1024 * 1024);

        return .{
            .status = response.head.status,
            .body = response_body,
            .allocator = allocator,
        };
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }

    fn parseJson(self: *const HttpResponse) !json.Parsed(json.Value) {
        return try json.parseFromSlice(json.Value, self.allocator, self.body, .{});
    }
};

var test_threaded: ?std.Io.Threaded = null;

fn testIo() std.Io {
    if (test_threaded == null) {
        test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return test_threaded.?.io();
}

fn uniquePort(seed: u64) u16 {
    return @intCast(49152 + (seed % 16384));
}

fn uniqueDataPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "/tmp/tt-http-{s}.json", .{name});
}

// ============================================================================
// Test cases
// ============================================================================

test "HTTP integration: POST /pursuits with valid body returns 201 with created pursuit" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "post-valid");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2001));
    defer server.deinit();

    const body =
        \\{"name":"AWS Certified Solutions Architect","type":"certification","target_date":"2026-12-31T23:59:59Z","started_at":"2026-06-01T00:00:00Z","tags":["cloud","aws"]}
    ;

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("id"));
    try testing.expectEqualStrings("AWS Certified Solutions Architect", obj.get("name").?.string);
    try testing.expectEqualStrings("certification", obj.get("type").?.string);
    try testing.expectEqualStrings("planned", obj.get("status").?.string);
    try testing.expect(obj.contains("target_date"));
    try testing.expect(obj.contains("started_at"));
    try testing.expect(obj.get("tags").?.array.items.len == 2);
    try testing.expect(obj.get("milestones").?.array.items.len == 0);
}

test "HTTP integration: POST /pursuits with missing required fields returns 400" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "post-missing");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2002));
    defer server.deinit();

    const body =
        \\{"type":"training","target_date":"2026-12-31T00:00:00Z"}
    ;

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.bad_request, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("status"));
    try testing.expect(obj.contains("message"));
    try testing.expectEqual(@as(i64, 400), obj.get("status").?.integer);
}

test "HTTP integration: POST /pursuits with validation errors returns 400" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "post-validation");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2003));
    defer server.deinit();

    const long_name = "A" ** 201;
    const body = try std.fmt.allocPrint(testing.allocator,
        \\{{"name":"{s}","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}}
    , .{long_name});
    defer testing.allocator.free(body);

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.bad_request, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 400), obj.get("status").?.integer);
}

test "HTTP integration: POST /pursuits then GET /pursuits/{id} round-trip" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "roundtrip");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2004));
    defer server.deinit();

    const create_body =
        \\{"name":"Kubernetes Admin","type":"certification","target_date":"2027-03-15T00:00:00Z","started_at":"2026-06-19T00:00:00Z","description":"CKA prep"}
    ;

    var create_resp = try server.request(testing.allocator, .POST, "/pursuits", create_body);
    defer create_resp.deinit();

    try testing.expectEqual(std.http.Status.created, create_resp.status);

    const create_parsed = try create_resp.parseJson();
    defer create_parsed.deinit();

    const id = create_parsed.value.object.get("id").?.string;

    const get_path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(get_path);

    var get_resp = try server.request(testing.allocator, .GET, get_path, "");
    defer get_resp.deinit();

    try testing.expectEqual(std.http.Status.ok, get_resp.status);

    const get_parsed = try get_resp.parseJson();
    defer get_parsed.deinit();

    const obj = get_parsed.value.object;
    try testing.expectEqualStrings(id, obj.get("id").?.string);
    try testing.expectEqualStrings("Kubernetes Admin", obj.get("name").?.string);
    try testing.expectEqualStrings("certification", obj.get("type").?.string);
    try testing.expectEqualStrings("planned", obj.get("status").?.string);
    try testing.expectEqualStrings("CKA prep", obj.get("description").?.string);
}

test "HTTP integration: POST /pursuits with inline milestones creates them" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "milestones");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2005));
    defer server.deinit();

    const body =
        \\{"name":"GCP Professional Architect","type":"certification","target_date":"2027-06-01T00:00:00Z","started_at":"2026-06-19T00:00:00Z","milestones":[{"name":"Complete course","date":"2026-08-01T00:00:00Z"},{"name":"Pass exam","date":"2027-05-15T00:00:00Z","state":"pending"}]}
    ;

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    const milestones = obj.get("milestones").?.array;
    try testing.expectEqual(@as(usize, 2), milestones.items.len);

    const m1 = milestones.items[0].object;
    try testing.expect(m1.contains("id"));
    try testing.expectEqualStrings("Complete course", m1.get("name").?.string);
    try testing.expectEqualStrings("pending", m1.get("state").?.string);

    const m2 = milestones.items[1].object;
    try testing.expect(m2.contains("id"));
    try testing.expectEqualStrings("Pass exam", m2.get("name").?.string);
    try testing.expectEqualStrings("pending", m2.get("state").?.string);
}

test "HTTP integration: GET /pursuits/{id} with unknown id returns 404" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "get-404");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2006));
    defer server.deinit();

    var resp = try server.request(testing.allocator, .GET, "/pursuits/does-not-exist", "");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.not_found, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 404), obj.get("status").?.integer);
    try testing.expect(obj.contains("message"));
}

test "HTTP integration: POST /pursuits with status=completed auto-sets completed_at" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "completed");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2007));
    defer server.deinit();

    const body =
        \\{"name":"Already Done","type":"training","status":"completed","target_date":"2026-06-01T00:00:00Z","started_at":"2026-05-01T00:00:00Z"}
    ;

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try resp.parseJson();
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("completed", obj.get("status").?.string);
    try testing.expect(obj.contains("completed_at"));
    try testing.expect(obj.get("completed_at").? != .null);
}

test "HTTP integration: POST /pursuits with invalid JSON returns 400" {
    const io = testIo();
    const data_path = try uniqueDataPath(testing.allocator, "invalid-json");
    defer testing.allocator.free(data_path);
    defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

    var server = try TestServer.spawn(testing.allocator, io, data_path, uniquePort(2008));
    defer server.deinit();

    const body = "not json at all";

    var resp = try server.request(testing.allocator, .POST, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.bad_request, resp.status);
}

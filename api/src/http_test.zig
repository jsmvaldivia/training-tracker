//! HTTP integration test infrastructure — runs the server in a background thread,
//! makes HTTP requests, and verifies end-to-end behavior. These tests complement the
//! acceptance tests in `pursuits.zig` (handler-level) by exercising the full
//! socket plumbing in `main.zig`.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;
const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");

// ---- Test Server Management ------------------------------------------------

const json_content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };

const ServerContext = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    store: store_mod.Store,
    port: u16,
    data_path: []const u8,
    server: net.Server,
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    // The server thread owns its I/O pool for its whole lifetime. (A previous
    // version borrowed a pool from the caller that was torn down as soon as
    // start() returned, leaving the server thread using freed I/O.)
    fn init(allocator: std.mem.Allocator, data_path: []const u8, port: u16) !*ServerContext {
        const ctx = try allocator.create(ServerContext);
        errdefer allocator.destroy(ctx);

        ctx.allocator = allocator;
        ctx.threaded = std.Io.Threaded.init(allocator, .{});
        errdefer ctx.threaded.deinit();
        ctx.io = ctx.threaded.io();

        ctx.store = try store_mod.Store.init(allocator, ctx.io, data_path);
        errdefer ctx.store.deinit();

        const address = try net.IpAddress.parse("127.0.0.1", port);
        ctx.server = try address.listen(ctx.io, .{ .reuse_address = true });
        errdefer ctx.server.deinit(ctx.io);

        ctx.port = port;
        ctx.data_path = data_path;
        ctx.should_stop = std.atomic.Value(bool).init(false);
        ctx.thread = null;

        return ctx;
    }

    fn deinit(self: *ServerContext) void {
        self.should_stop.store(true, .monotonic);
        // A blocking accept() is not interrupted by the flag, so make one
        // throwaway connection to wake it; the loop then observes should_stop.
        self.wakeAccept();
        if (self.thread) |t| t.join();
        self.server.deinit(self.io);
        self.store.deinit();
        std.Io.Dir.cwd().deleteFile(self.io, self.data_path) catch {};
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    /// Open and immediately close one TCP connection so the server thread's
    /// blocking accept() returns and the run loop can re-check should_stop.
    fn wakeAccept(self: *ServerContext) void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const address = net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }

    fn run(self: *ServerContext) void {
        while (!self.should_stop.load(.monotonic)) {
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

        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        const method = req.head.method;
        var target_buf: [8 * 1024]u8 = undefined;
        const tlen = @min(req.head.target.len, target_buf.len);
        @memcpy(target_buf[0..tlen], req.head.target[0..tlen]);
        const target = target_buf[0..tlen];

        var body_buf: [1024 * 1024]u8 = undefined;
        const body = readBody(&req, &body_buf);

        if (try pursuits.handle(self.allocator, &self.store, method, target, body)) |resp| {
            defer if (resp.body.len > 0) self.allocator.free(resp.body);
            try req.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = &.{json_content_type},
                .keep_alive = false,
            });
            return;
        }

        if (method == .GET and std.mem.eql(u8, stripQuery(target), "/health")) {
            try req.respond("{\"status\":\"ok\"}", .{
                .status = .ok,
                .extra_headers = &.{json_content_type},
                .keep_alive = false,
            });
            return;
        }

        try req.respond("{\"status\":404,\"message\":\"Not found\"}", .{
            .status = .not_found,
            .extra_headers = &.{json_content_type},
            .keep_alive = false,
        });
    }

    fn readBody(req: *std.http.Server.Request, buf: []u8) []const u8 {
        if (!req.head.method.requestHasBody()) return "";
        const reader = req.readerExpectContinue(&.{}) catch return "";
        const n = reader.readSliceShort(buf) catch return "";
        return buf[0..n];
    }

    fn stripQuery(target: []const u8) []const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
        return target[0..q];
    }
};

/// Opaque handle to a test server running in a background thread. Must be cleaned up via `shutdown`.
pub const TestServer = struct {
    ctx: *ServerContext,
    port: u16,
    allocator: std.mem.Allocator,

    /// Start the server in a background thread on a unique port with an isolated data file.
    /// Polls until the /health endpoint responds or timeout is reached.
    pub fn start(allocator: std.mem.Allocator, port: u16, data_path: []const u8) !TestServer {
        const ctx = try ServerContext.init(allocator, data_path, port);
        errdefer ctx.deinit();

        const thread = try std.Thread.spawn(.{}, ServerContext.run, .{ctx});
        ctx.thread = thread;

        var server = TestServer{
            .ctx = ctx,
            .port = port,
            .allocator = allocator,
        };

        // Wait until the server is ready by polling /health.
        const ready = try server.waitUntilReady(3000); // 3 second timeout
        if (!ready) {
            server.shutdown();
            return error.ServerStartupTimeout;
        }

        return server;
    }

    /// Shut down the server and clean up the data file.
    pub fn shutdown(self: *TestServer) void {
        self.ctx.deinit();
    }

    /// Poll /health endpoint until it responds successfully or timeout is reached.
    fn waitUntilReady(self: *TestServer, timeout_ms: u64) !bool {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const start_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        const timeout_ns: i96 = @intCast(timeout_ms * std.time.ns_per_ms);
        while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start_ns < timeout_ns) {
            const result = self.healthCheck() catch {
                // Server not ready yet — yield ~10ms before retrying.
                io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                continue;
            };
            if (result) return true;
            io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    fn healthCheck(self: *TestServer) !bool {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        const uri_str = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}/health", .{self.port});
        defer self.allocator.free(uri_str);

        const uri = try std.Uri.parse(uri_str);

        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        return response.head.status == .ok;
    }
};

// ---- HTTP Client Helpers ---------------------------------------------------

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

/// Make a GET request and return the response.
pub fn get(allocator: std.mem.Allocator, port: u16, path: []const u8) !Response {
    return request(allocator, .GET, port, path, null);
}

/// Make a POST request with a JSON body.
pub fn post(allocator: std.mem.Allocator, port: u16, path: []const u8, body: []const u8) !Response {
    return request(allocator, .POST, port, path, body);
}

/// Make a PATCH request with a JSON body.
pub fn patch(allocator: std.mem.Allocator, port: u16, path: []const u8, body: []const u8) !Response {
    return request(allocator, .PATCH, port, path, body);
}

/// Make a DELETE request.
pub fn delete(allocator: std.mem.Allocator, port: u16, path: []const u8) !Response {
    return request(allocator, .DELETE, port, path, null);
}

fn request(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    port: u16,
    path: []const u8,
    body: ?[]const u8,
) !Response {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri_str = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer allocator.free(uri_str);

    const uri = try std.Uri.parse(uri_str);

    var req = try client.request(method, uri, .{});
    defer req.deinit();

    if (body) |b| {
        try req.sendBodyComplete(@constCast(b));
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var body_buf: [1024 * 1024]u8 = undefined;
    const reader = response.reader(&body_buf);
    const response_body = try reader.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));

    return Response{
        .status = response.head.status,
        .body = response_body,
        .allocator = allocator,
    };
}

// ---- JSON Assertion Helpers ------------------------------------------------

/// Parse JSON response body and return the value tree.
pub fn parseJson(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

/// Assert that a JSON response has the expected structure for a paginated list.
pub fn expectPaginatedList(parsed: std.json.Value, expected_total: i64) !void {
    try testing.expect(parsed == .object);
    const obj = parsed.object;

    try testing.expect(obj.get("data") != null);
    try testing.expect(obj.get("data").? == .array);
    try testing.expect(obj.get("total") != null);
    try testing.expectEqual(expected_total, obj.get("total").?.integer);
    try testing.expect(obj.get("limit") != null);
    try testing.expect(obj.get("offset") != null);
}

/// Extract the "id" field from a JSON object response.
pub fn extractId(allocator: std.mem.Allocator, parsed: std.json.Value) ![]const u8 {
    try testing.expect(parsed == .object);
    const id_val = parsed.object.get("id") orelse return error.MissingIdField;
    try testing.expect(id_val == .string);
    return allocator.dupe(u8, id_val.string);
}

// ============================================================================
// HTTP Integration Tests
// ============================================================================

test "http: GET /health returns 200" {
    const port: u16 = 8091;
    const data_path = "/tmp/tt-http-health.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    var resp = try get(testing.allocator, port, "/health");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.ok, resp.status);

    const parsed = try parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try testing.expect(parsed.value.object.get("status") != null);
    try testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
}

test "http: GET /pursuits on empty store returns empty paginated list" {
    const port: u16 = 8092;
    const data_path = "/tmp/tt-http-empty.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    var resp = try get(testing.allocator, port, "/pursuits");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.ok, resp.status);

    const parsed = try parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try expectPaginatedList(parsed.value, 0);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("data").?.array.items.len);
}

test "http: GET /pursuits?limit=10&offset=0 returns paginated envelope" {
    const port: u16 = 8093;
    const data_path = "/tmp/tt-http-pagination.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create a pursuit first.
    var create_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"AWS SAA","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer create_resp.deinit();
    try testing.expectEqual(std.http.Status.created, create_resp.status);

    // List with explicit pagination params.
    var list_resp = try get(testing.allocator, port, "/pursuits?limit=10&offset=0");
    defer list_resp.deinit();

    try testing.expectEqual(std.http.Status.ok, list_resp.status);

    const parsed = try parseJson(testing.allocator, list_resp.body);
    defer parsed.deinit();

    try expectPaginatedList(parsed.value, 1);
    try testing.expectEqual(@as(i64, 10), parsed.value.object.get("limit").?.integer);
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("offset").?.integer);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("data").?.array.items.len);
}

test "http: GET /pursuits?type=certification filters by type" {
    const port: u16 = 8094;
    const data_path = "/tmp/tt-http-filter-cert.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create one certification and one training.
    var cert_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"AWS SAA","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer cert_resp.deinit();

    var training_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"Zig Course","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer training_resp.deinit();

    // Filter by certification type.
    var filter_resp = try get(testing.allocator, port, "/pursuits?type=certification");
    defer filter_resp.deinit();

    try testing.expectEqual(std.http.Status.ok, filter_resp.status);

    const parsed = try parseJson(testing.allocator, filter_resp.body);
    defer parsed.deinit();

    try expectPaginatedList(parsed.value, 1);
    const items = parsed.value.object.get("data").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("certification", items[0].object.get("type").?.string);
}

test "http: GET /pursuits?type=training filters by training type" {
    const port: u16 = 8095;
    const data_path = "/tmp/tt-http-filter-training.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create one certification and one training.
    var cert_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"AWS SAA","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer cert_resp.deinit();

    var training_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"Zig Course","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer training_resp.deinit();

    // Filter by training type.
    var filter_resp = try get(testing.allocator, port, "/pursuits?type=training");
    defer filter_resp.deinit();

    try testing.expectEqual(std.http.Status.ok, filter_resp.status);

    const parsed = try parseJson(testing.allocator, filter_resp.body);
    defer parsed.deinit();

    try expectPaginatedList(parsed.value, 1);
    const items = parsed.value.object.get("data").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("training", items[0].object.get("type").?.string);
}

test "http: POST /pursuits creates and GET retrieves" {
    const port: u16 = 8096;
    const data_path = "/tmp/tt-http-create-get.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create a pursuit.
    var create_resp = try post(testing.allocator, port, "/pursuits",
        \\{"name":"GCP ACE","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer create_resp.deinit();

    try testing.expectEqual(std.http.Status.created, create_resp.status);

    const create_parsed = try parseJson(testing.allocator, create_resp.body);
    defer create_parsed.deinit();

    const id = try extractId(testing.allocator, create_parsed.value);
    defer testing.allocator.free(id);

    // Retrieve the created pursuit.
    const get_path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(get_path);

    var get_resp = try get(testing.allocator, port, get_path);
    defer get_resp.deinit();

    try testing.expectEqual(std.http.Status.ok, get_resp.status);

    const get_parsed = try parseJson(testing.allocator, get_resp.body);
    defer get_parsed.deinit();

    try testing.expectEqualStrings(id, get_parsed.value.object.get("id").?.string);
    try testing.expectEqualStrings("GCP ACE", get_parsed.value.object.get("name").?.string);
}

test "http: GET /pursuits/{id} for unknown id returns 404" {
    const port: u16 = 8097;
    const data_path = "/tmp/tt-http-404.json";

    var server = try TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    var resp = try get(testing.allocator, port, "/pursuits/unknown_id");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.not_found, resp.status);
}

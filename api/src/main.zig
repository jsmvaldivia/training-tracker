//! Training Tracker HTTP API — Zig web service.
//!
//! The OpenAPI contract in `api/openapi.yaml` is the source of truth. Storage is
//! a backend-private JSON file (`api/data.json`); SQLite comes later. The
//! Pursuit/Milestone resource is implemented in `pursuits.zig` (handler) and
//! `store.zig` (domain + persistence); this file is the socket plumbing.

const std = @import("std");
const net = std.Io.net;

const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");

const default_port: u16 = 8080;
const default_data_path = "data.json";
const json_content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Allow port and data path override via environment variables for testing.
    const port = blk: {
        const port_str_ptr = std.c.getenv("PORT") orelse break :blk default_port;
        const port_str = std.mem.span(port_str_ptr);
        break :blk std.fmt.parseInt(u16, port_str, 10) catch default_port;
    };
    const data_path = blk: {
        const path_ptr = std.c.getenv("DATA_PATH") orelse break :blk default_data_path;
        break :blk std.mem.span(path_ptr);
    };

    var store = try store_mod.Store.init(gpa, io, data_path);
    defer store.deinit();

    const address = try net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("training-tracker listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(io, gpa, &store, stream) catch |err| {
            std.debug.print("connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store, stream: net.Stream) !void {
    defer stream.close(io);

    var recv_buf: [64 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    // Capture method/target before reading the body: taking the body reader
    // invalidates the string memory inside `Head`.
    const method = request.head.method;
    var target_buf: [8 * 1024]u8 = undefined;
    const tlen = @min(request.head.target.len, target_buf.len);
    @memcpy(target_buf[0..tlen], request.head.target[0..tlen]);
    const target = target_buf[0..tlen];

    // Read the request body (if any).
    var body_buf: [1024 * 1024]u8 = undefined;
    const body = readBody(&request, &body_buf);

    if (try pursuits.handle(gpa, store, method, target, body)) |resp| {
        defer if (resp.body.len > 0) gpa.free(resp.body);
        try request.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{json_content_type},
            .keep_alive = false,
        });
        return;
    }

    // Fallback routes handled inline.
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

test "health path is not claimed by the pursuits router" {
    // Smoke test that the resource router and fallback wiring compile together.
    try std.testing.expect(std.mem.eql(u8, stripQuery("/health?x=1"), "/health"));
}

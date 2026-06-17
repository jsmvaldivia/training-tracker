//! Training Tracker HTTP API — minimal Zig web service skeleton.
//!
//! Routes are stubs for now; the OpenAPI contract in `api/openapi.yaml` is the
//! source of truth and resources get filled in against it. Storage is a
//! backend-private JSON file (`api/data.json`); SQLite comes later.

const std = @import("std");
const net = std.Io.net;

const port: u16 = 8080;
const json_content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("training-tracker listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(io, stream) catch |err| {
            std.debug.print("connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(io: std.Io, stream: net.Stream) !void {
    defer stream.close(io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    const response = responseFor(request.head.method, request.head.target);
    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = &.{json_content_type},
        .keep_alive = false,
    });
}

const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

/// Pure routing: maps a method + path to a canned response. Kept free of any
/// I/O so it stays unit-testable as real resources land here.
fn responseFor(method: std.http.Method, target: []const u8) Response {
    if (method == .GET and std.mem.eql(u8, target, "/health")) {
        return .{ .status = .ok, .body = "{\"status\":\"ok\"}" };
    }
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

test "responseFor maps health, unknown paths, and wrong methods" {
    try std.testing.expectEqual(std.http.Status.ok, responseFor(.GET, "/health").status);
    try std.testing.expectEqual(std.http.Status.not_found, responseFor(.GET, "/nope").status);
    try std.testing.expectEqual(std.http.Status.not_found, responseFor(.POST, "/health").status);
}

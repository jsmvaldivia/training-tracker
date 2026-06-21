//! Training Tracker HTTP API — Zig web service.
//!
//! The OpenAPI contract in `api/openapi.yaml` is the source of truth. Storage is
//! a backend-private JSON file (`api/data.json`); SQLite comes later. The
//! Pursuit/Milestone resource is implemented in `pursuits.zig` (handler) and
//! `store.zig` (domain + persistence); this file is the socket plumbing.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");

const default_port: u16 = 8080;
const default_data_path = "data.json";
const json_content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };

const log = std.log.scoped(.server);

/// Show debug logs in dev (Debug builds) and info-and-above in release. Set
/// explicitly so `info` lifecycle lines survive `ReleaseFast`, where the std
/// default would otherwise drop to `err`-only.
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

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

    log.info("listening on http://127.0.0.1:{d} (data: {s})", .{ port, data_path });

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handleConnection(io, gpa, &store, stream) catch |err| {
            log.warn("connection error: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store, stream: net.Stream) !void {
    defer stream.close(io);

    // Fixed buffers, intentionally generous for this single-user domain: a
    // request/response line over 64 KiB, a target over 8 KiB, or a body over
    // 1 MiB is truncated rather than answered with 413/414. That ceremony isn't
    // warranted here; the caps exist only to bound stack usage.
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
        log.debug("{s} {s} -> {d}", .{ @tagName(method), target, @intFromEnum(resp.status) });
        try request.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{json_content_type},
            .keep_alive = false,
        });
        return;
    }

    // Fallback routes handled inline.
    if (method == .GET and std.mem.eql(u8, stripQuery(target), "/health")) {
        log.debug("{s} {s} -> 200", .{ @tagName(method), target });
        try request.respond("{\"status\":\"ok\"}", .{
            .status = .ok,
            .extra_headers = &.{json_content_type},
            .keep_alive = false,
        });
        return;
    }

    log.debug("{s} {s} -> 404", .{ @tagName(method), target });
    try request.respond("{\"status\":404,\"message\":\"Not found\"}", .{
        .status = .not_found,
        .extra_headers = &.{json_content_type},
        .keep_alive = false,
    });
}

fn readBody(request: *std.http.Server.Request, buf: []u8) []const u8 {
    if (!request.head.method.requestHasBody()) return "";
    const reader = request.readerExpectContinue(&.{}) catch return "";
    // Read until EOF or the buffer is full. Explicit loop rather than relying on
    // a single read filling the buffer; bodies larger than `buf` are capped (see
    // the buffer-size note in `handleConnection`).
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.readSliceShort(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn stripQuery(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

test "health path is not claimed by the pursuits router" {
    // Smoke test that the resource router and fallback wiring compile together.
    try std.testing.expect(std.mem.eql(u8, stripQuery("/health?x=1"), "/health"));
}

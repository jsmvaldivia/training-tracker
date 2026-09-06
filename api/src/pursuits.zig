//! HTTP handler layer for the Pursuit (and nested Milestone) resource.
//!
//! Routing is kept I/O-free: `handle` takes a parsed request (method, path,
//! query, body bytes) plus a `*Store`, and returns a `Response` (status +
//! JSON body bytes owned by `gpa`). The socket plumbing in `main.zig` adapts
//! real requests onto this function, which keeps the whole resource
//! unit/acceptance-testable without opening sockets.
//!
//! Status codes, request/response shapes, and error mappings come straight
//! from `api/openapi.yaml`.

const std = @import("std");
const builtin = @import("builtin");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const StoreError = store_mod.StoreError;

const json = std.json;
const Allocator = std.mem.Allocator;
const Value = json.Value;

const log = std.log.scoped(.handler);

/// Flush the store to disk before reporting mutation success. The mutation has
/// already changed the in-memory tree; on failure we return 500 so the client
/// does not treat the change as durable. A later successful flush may still
/// persist that in-memory state.
fn persistOr500(gpa: Allocator, s: *Store) Allocator.Error!?Response {
    s.flush() catch |err| {
        // Skip the log in test builds: the failure-path test deliberately forces
        // a flush error, and Zig's default test runner fails any test that emits
        // an `err`-level log. Production keeps the `err` log — a write failure
        // must surface even though the client already got its 500.
        if (!builtin.is_test)
            log.err("failed to persist store to disk: {s}", .{@errorName(err)});
        return try errorResponse(gpa, .internal_server_error, "Failed to persist change", null);
    };
    return null;
}

pub const Response = struct {
    status: std.http.Status,
    /// JSON body, allocated with the handler's gpa. Empty for 204.
    body: []const u8,
    /// Value of the `Allow` header; set only on 405 (RFC 9110 requires it).
    allow: ?[]const u8 = null,
};

/// Routes a pursuit/milestone request. Returns null if the path does not
/// belong to this resource (so the caller can fall through to other routes
/// like /health). `caller` owns `response.body` and must free it.
pub fn handle(
    gpa: Allocator,
    s: *Store,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) Allocator.Error!?Response {
    const path = stripQuery(target);
    const query = extractQuery(target);

    if (!isPursuitPath(path)) return null;

    // Split path into segments after the leading "/pursuits".
    // Possible shapes:
    //   /pursuits
    //   /pursuits/{id}
    //   /pursuits/{id}/milestones
    //   /pursuits/{id}/milestones/{milestoneId}
    const route = Route.parse(path);

    return switch (route.kind) {
        .collection => switch (method) {
            .GET => try listPursuits(gpa, s, query),
            .POST => try createPursuit(gpa, s, body),
            else => try methodNotAllowed(gpa, "GET, POST"),
        },
        .item => switch (method) {
            .GET => try getPursuit(gpa, s, route.id.?),
            .PATCH => try updatePursuit(gpa, s, route.id.?, body),
            .DELETE => try deletePursuit(gpa, s, route.id.?),
            else => try methodNotAllowed(gpa, "GET, PATCH, DELETE"),
        },
        .milestones => switch (method) {
            .POST => try createMilestone(gpa, s, route.id.?, body),
            else => try methodNotAllowed(gpa, "POST"),
        },
        .milestone_item => switch (method) {
            .PATCH => try updateMilestone(gpa, s, route.id.?, route.milestone_id.?, body),
            .DELETE => try deleteMilestone(gpa, s, route.id.?, route.milestone_id.?),
            else => try methodNotAllowed(gpa, "PATCH, DELETE"),
        },
        .none => null,
    };
}

/// The contract's MethodNotAllowed response: Error body plus the `Allow`
/// header naming what the path does support.
pub fn methodNotAllowed(gpa: Allocator, allow: []const u8) Allocator.Error!Response {
    var r = try errorResponse(gpa, .method_not_allowed, "Method not allowed", null);
    r.allow = allow;
    return r;
}

// ---- Operations ----------------------------------------------------------

fn listPursuits(gpa: Allocator, s: *Store, query: []const u8) Allocator.Error!Response {
    // `type` is percent-decoded into this buffer; `params.type_filter` borrows it.
    var type_buf: [64]u8 = undefined;
    const params = switch (parseListParams(query, &type_buf)) {
        .ok => |p| p,
        .invalid => |details| return errorResponse(gpa, .bad_request, "Invalid query parameter", details),
    };

    // Request-scoped arena: owns both the store's transient `matched` array and
    // the response envelope, all freed when this handler returns.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const res = s.list(a, params.type_filter, params.limit, params.offset) catch return oomRaw(gpa);

    // Build the PursuitsListResponse envelope as a Value.
    var arr = json.Array.init(a);
    for (res.data) |p| arr.append(p) catch return oomRaw(gpa);

    var obj = json.ObjectMap{};
    obj.put(a, "data", .{ .array = arr }) catch return oomRaw(gpa);
    obj.put(a, "total", .{ .integer = @intCast(res.total) }) catch return oomRaw(gpa);
    obj.put(a, "limit", .{ .integer = @intCast(res.limit) }) catch return oomRaw(gpa);
    obj.put(a, "offset", .{ .integer = @intCast(res.offset) }) catch return oomRaw(gpa);

    return jsonResponse(gpa, .ok, .{ .object = obj });
}

fn createPursuit(gpa: Allocator, s: *Store, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const created = s.create(parsed.value) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .created, created);
}

fn getPursuit(gpa: Allocator, s: *Store, id: []const u8) Allocator.Error!Response {
    const p = s.get(id) catch |err| return mapStoreError(gpa, s, err);
    return jsonResponse(gpa, .ok, p);
}

fn updatePursuit(gpa: Allocator, s: *Store, id: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const updated = s.update(id, parsed.value) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .ok, updated);
}

fn deletePursuit(gpa: Allocator, s: *Store, id: []const u8) Allocator.Error!Response {
    s.delete(id) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return .{ .status = .no_content, .body = "" };
}

fn createMilestone(gpa: Allocator, s: *Store, pid: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const m = s.createMilestone(pid, parsed.value) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .created, m);
}

fn updateMilestone(gpa: Allocator, s: *Store, pid: []const u8, mid: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const m = s.updateMilestone(pid, mid, parsed.value) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .ok, m);
}

fn deleteMilestone(gpa: Allocator, s: *Store, pid: []const u8, mid: []const u8) Allocator.Error!Response {
    s.deleteMilestone(pid, mid) catch |err| return mapStoreError(gpa, s, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return .{ .status = .no_content, .body = "" };
}

// ---- Query parsing --------------------------------------------------------

const ListParams = struct {
    limit: usize = 50,
    offset: usize = 0,
    type_filter: ?[]const u8 = null,
};

const ListParamsResult = union(enum) {
    ok: ListParams,
    /// The `details` text for the 400: names the parameter and its rule.
    invalid: []const u8,
};

const limit_rule = "Query parameter 'limit' must be an integer between 1 and 100";
const offset_rule = "Query parameter 'offset' must be an integer of 0 or more";
const type_rule = "Query parameter 'type' must be one of: certification, training";

/// Parses `GET /pursuits` query parameters against the contract: `limit` in
/// 1..100 (default 50), `offset` >= 0 (default 0), `type` a `PursuitType`.
/// Out-of-range or malformed values are rejected — never clamped or coerced —
/// so the response always reflects what the client asked for. Values are
/// percent-decoded first; `type` is decoded into `type_buf`, which the
/// returned `type_filter` borrows. Unknown keys are ignored.
fn parseListParams(query: []const u8, type_buf: []u8) ListParamsResult {
    var params: ListParams = .{};

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (eq) |e| pair[0..e] else pair;
        const raw_val = if (eq) |e| pair[e + 1 ..] else "";

        var key_buf: [16]u8 = undefined;
        // A key longer than any contract parameter cannot be one of them.
        const key = percentDecode(&key_buf, raw_key) orelse continue;

        if (std.mem.eql(u8, key, "limit")) {
            var buf: [32]u8 = undefined;
            const val = percentDecode(&buf, raw_val) orelse return .{ .invalid = limit_rule };
            const n = std.fmt.parseInt(usize, val, 10) catch return .{ .invalid = limit_rule };
            if (n < 1 or n > 100) return .{ .invalid = limit_rule };
            params.limit = n;
        } else if (std.mem.eql(u8, key, "offset")) {
            var buf: [32]u8 = undefined;
            const val = percentDecode(&buf, raw_val) orelse return .{ .invalid = offset_rule };
            // parseInt(usize) already rejects a leading '-', an empty string,
            // and anything non-numeric.
            params.offset = std.fmt.parseInt(usize, val, 10) catch return .{ .invalid = offset_rule };
        } else if (std.mem.eql(u8, key, "type")) {
            const val = percentDecode(type_buf, raw_val) orelse return .{ .invalid = type_rule };
            if (!store_mod.isPursuitType(val)) return .{ .invalid = type_rule };
            params.type_filter = val;
        }
    }
    return .{ .ok = params };
}

/// Percent-decodes `raw` into `buf`; null when `raw` cannot fit (decoding never
/// grows a string, so a raw value longer than the buffer is simply too long).
fn percentDecode(buf: []u8, raw: []const u8) ?[]const u8 {
    if (raw.len > buf.len) return null;
    return std.Uri.percentDecodeBackwards(buf, raw);
}

// ---- Routing helpers ------------------------------------------------------

const RouteKind = enum { none, collection, item, milestones, milestone_item };

const Route = struct {
    kind: RouteKind,
    id: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,

    fn parse(path: []const u8) Route {
        // path is guaranteed to start with "/pursuits".
        if (std.mem.eql(u8, path, "/pursuits") or std.mem.eql(u8, path, "/pursuits/")) {
            return .{ .kind = .collection };
        }
        // Strip "/pursuits/" prefix.
        const rest = path["/pursuits/".len..];
        var it = std.mem.splitScalar(u8, rest, '/');
        const id = it.next() orelse return .{ .kind = .none };
        if (id.len == 0) return .{ .kind = .none };

        const seg2 = it.next();
        if (seg2 == null) return .{ .kind = .item, .id = id };
        if (!std.mem.eql(u8, seg2.?, "milestones")) return .{ .kind = .none };

        const mid = it.next();
        if (mid == null or mid.?.len == 0) return .{ .kind = .milestones, .id = id };
        // Reject trailing extra segments.
        if (it.next() != null) return .{ .kind = .none };
        return .{ .kind = .milestone_item, .id = id, .milestone_id = mid.? };
    }
};

fn isPursuitPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/pursuits") or std.mem.startsWith(u8, path, "/pursuits/");
}

fn stripQuery(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

fn extractQuery(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[q + 1 ..];
}

// ---- Response building ----------------------------------------------------

fn parseBody(gpa: Allocator, body: []const u8) !json.Parsed(Value) {
    return json.parseFromSlice(Value, gpa, body, .{});
}

/// Parse a JSON request body, or yield a ready 400 response. Centralizes the
/// parse + "Invalid JSON body" mapping shared by every mutating handler.
/// On `.ok`, the caller owns the `Parsed` and must `defer parsed.deinit()`.
const BodyOr400 = union(enum) { ok: json.Parsed(Value), err: Response };

fn parseBodyOr400(gpa: Allocator, body: []const u8) Allocator.Error!BodyOr400 {
    if (parseBody(gpa, body)) |parsed| {
        return .{ .ok = parsed };
    } else |err| {
        var buf: [96]u8 = undefined;
        const details = std.fmt.bufPrint(&buf, "Request body is not valid JSON ({s})", .{@errorName(err)}) catch
            "Request body is not valid JSON";
        return .{ .err = try errorResponse(gpa, .bad_request, "Invalid JSON body", details) };
    }
}

fn jsonResponse(gpa: Allocator, status: std.http.Status, value: Value) Allocator.Error!Response {
    const bytes = json.Stringify.valueAlloc(gpa, value, .{}) catch return oomRaw(gpa);
    return .{ .status = status, .body = bytes };
}

const StoreOrOom = StoreError || Allocator.Error;

/// Maps a store error to its contract status. For `error.Invalid` the store's
/// diagnostic (which field, which rule) becomes `Error.details`.
fn mapStoreError(gpa: Allocator, s: *Store, err: StoreOrOom) Allocator.Error!Response {
    log.debug("store rejected request: {s}", .{@errorName(err)});
    return switch (err) {
        error.Invalid => errorResponse(gpa, .bad_request, "Invalid request body", s.diag.message()),
        error.Conflict => errorResponse(gpa, .conflict, "Milestone limit reached", s.diag.message()),
        error.PursuitNotFound => errorResponse(gpa, .not_found, "Pursuit not found", null),
        error.MilestoneNotFound => errorResponse(gpa, .not_found, "Milestone not found", null),
        error.OutOfMemory => oomRaw(gpa),
    };
}

/// Build an error body via `json.Stringify` (the same path as success
/// responses) so `message`/`details` are always correctly escaped — never
/// hand-rolled string interpolation, which would emit invalid JSON the moment
/// a value contained a quote or backslash.
fn errorResponse(gpa: Allocator, status: std.http.Status, message: []const u8, details: ?[]const u8) Allocator.Error!Response {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var obj = json.ObjectMap{};
    obj.put(a, "status", .{ .integer = @intFromEnum(status) }) catch return oomRaw(gpa);
    obj.put(a, "message", .{ .string = message }) catch return oomRaw(gpa);
    if (details) |d| obj.put(a, "details", .{ .string = d }) catch return oomRaw(gpa);

    // Bind an explicit `Value`: `valueAlloc` takes `anytype`, so an inline
    // `.{ .object = obj }` would be stringified as a raw struct, not JSON.
    const v: Value = .{ .object = obj };
    const bytes = json.Stringify.valueAlloc(gpa, v, .{}) catch return oomRaw(gpa);
    return .{ .status = status, .body = bytes };
}

fn oomRaw(gpa: Allocator) Response {
    const body = gpa.dupe(u8, "{\"status\":500,\"message\":\"Internal error\"}") catch
        return .{ .status = .internal_server_error, .body = "" };
    return .{ .status = .internal_server_error, .body = body };
}

// =========================================================================
// Acceptance tests — one per OAS operation, exercising handler -> store and
// asserting the persistence side effect.
// =========================================================================

const testing = std.testing;

var test_threaded: ?std.Io.Threaded = null;

fn testIo() std.Io {
    if (test_threaded == null) {
        test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return test_threaded.?.io();
}

fn freshStore(path: []const u8) !Store {
    const io = testIo();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return Store.init(testing.allocator, io, path);
}

fn req(
    s: *Store,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) !Response {
    const r = (try handle(testing.allocator, s, method, target, body)).?;
    return r;
}

test "acceptance: POST /pursuits then GET /pursuits/{id} round-trips through the store" {
    const path = "/tmp/tt-acc-create.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const create = try req(&s, .POST, "/pursuits",
        \\{"name":"AWS SAA","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer testing.allocator.free(create.body);
    try testing.expectEqual(std.http.Status.created, create.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, create.body, .{});
    defer parsed.deinit();
    const id = try testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
    defer testing.allocator.free(id);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);
    const got = try req(&s, .GET, target, "");
    defer testing.allocator.free(got.body);
    try testing.expectEqual(std.http.Status.ok, got.status);

    // Persistence side effect: it was written to the file.
    var s2 = try Store.init(testing.allocator, testIo(), path);
    defer s2.deinit();
    var la = std.heap.ArenaAllocator.init(testing.allocator);
    defer la.deinit();
    const res = try s2.list(la.allocator(), null, 50, 0);
    try testing.expectEqual(@as(usize, 1), res.total);
}

test "acceptance: GET /pursuits returns a paginated envelope" {
    const path = "/tmp/tt-acc-list.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const c = try req(&s, .POST, "/pursuits",
        \\{"name":"a","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    testing.allocator.free(c.body);

    const list = try req(&s, .GET, "/pursuits?limit=10&offset=0", "");
    defer testing.allocator.free(list.body);
    try testing.expectEqual(std.http.Status.ok, list.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, list.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 10), parsed.value.object.get("limit").?.integer);
    try testing.expect(parsed.value.object.get("data").? == .array);
}

test "acceptance: POST /pursuits with invalid body returns 400" {
    const path = "/tmp/tt-acc-bad.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const r = try req(&s, .POST, "/pursuits", "{\"type\":\"training\"}");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.bad_request, r.status);
}

test "acceptance: GET /pursuits/{id} unknown returns 404" {
    const path = "/tmp/tt-acc-404.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const r = try req(&s, .GET, "/pursuits/nope", "");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.not_found, r.status);
}

test "acceptance: PATCH /pursuits/{id} updates and persists" {
    const path = "/tmp/tt-acc-patch.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const c = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const parsed = try json.parseFromSlice(Value, testing.allocator, c.body, .{});
    testing.allocator.free(c.body);
    const id = try testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
    parsed.deinit();
    defer testing.allocator.free(id);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);
    const r = try req(&s, .PATCH, target, "{\"status\":\"completed\"}");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.ok, r.status);

    const p2 = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
    defer p2.deinit();
    try testing.expect(p2.value.object.get("completed_at") != null);
}

test "acceptance: DELETE /pursuits/{id} returns 204 and removes from store" {
    const path = "/tmp/tt-acc-del.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const c = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const parsed = try json.parseFromSlice(Value, testing.allocator, c.body, .{});
    testing.allocator.free(c.body);
    const id = try testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
    parsed.deinit();
    defer testing.allocator.free(id);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);
    const r = try req(&s, .DELETE, target, "");
    try testing.expectEqual(std.http.Status.no_content, r.status);
    try testing.expectEqual(@as(usize, 0), r.body.len);

    try testing.expectError(StoreError.PursuitNotFound, s.get(id));
}

test "acceptance: milestone lifecycle POST/PATCH/DELETE" {
    const path = "/tmp/tt-acc-ms.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const c = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const parsed = try json.parseFromSlice(Value, testing.allocator, c.body, .{});
    testing.allocator.free(c.body);
    const pid = try testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
    parsed.deinit();
    defer testing.allocator.free(pid);

    const ms_path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(ms_path);

    const mc = try req(&s, .POST, ms_path,
        \\{"name":"Exam","date":"2026-07-15T00:00:00Z"}
    );
    try testing.expectEqual(std.http.Status.created, mc.status);
    const mp = try json.parseFromSlice(Value, testing.allocator, mc.body, .{});
    testing.allocator.free(mc.body);
    const mid = try testing.allocator.dupe(u8, mp.value.object.get("id").?.string);
    mp.deinit();
    defer testing.allocator.free(mid);

    const mitem_path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(mitem_path);

    const mu = try req(&s, .PATCH, mitem_path, "{\"state\":\"achieved\"}");
    defer testing.allocator.free(mu.body);
    try testing.expectEqual(std.http.Status.ok, mu.status);
    const mup = try json.parseFromSlice(Value, testing.allocator, mu.body, .{});
    defer mup.deinit();
    try testing.expect(mup.value.object.get("achieved_at") != null);

    const md = try req(&s, .DELETE, mitem_path, "");
    try testing.expectEqual(std.http.Status.no_content, md.status);
    try testing.expectEqual(@as(usize, 0), (try s.get(pid)).object.get("milestones").?.array.items.len);
}

test "acceptance: milestone on missing pursuit returns 404" {
    const path = "/tmp/tt-acc-ms404.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const r = try req(&s, .POST, "/pursuits/nope/milestones",
        \\{"name":"E","date":"2026-07-15T00:00:00Z"}
    );
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.not_found, r.status);
}

test "acceptance: POST /pursuits with a non-date-time target_date returns 400" {
    const path = "/tmp/tt-acc-baddate.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const r = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"someday","started_at":"2026-06-01T00:00:00Z"}
    );
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.bad_request, r.status);
}

test "acceptance: unsupported methods return 405 with an Allow header" {
    const path = "/tmp/tt-acc-405.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // Collection allows only GET/POST.
    const c = try req(&s, .PUT, "/pursuits", "");
    defer testing.allocator.free(c.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, c.status);
    try testing.expectEqualStrings("GET, POST", c.allow.?);

    // Item allows only GET/PATCH/DELETE (405 is decided before existence).
    const i = try req(&s, .POST, "/pursuits/p_1", "");
    defer testing.allocator.free(i.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, i.status);
    try testing.expectEqualStrings("GET, PATCH, DELETE", i.allow.?);

    // Milestones collection allows only POST.
    const m = try req(&s, .GET, "/pursuits/p_1/milestones", "");
    defer testing.allocator.free(m.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, m.status);
    try testing.expectEqualStrings("POST", m.allow.?);

    // Milestone item allows only PATCH/DELETE.
    const mi = try req(&s, .GET, "/pursuits/p_1/milestones/m_1", "");
    defer testing.allocator.free(mi.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, mi.status);
    try testing.expectEqualStrings("PATCH, DELETE", mi.allow.?);

    // A 2xx carries no Allow header.
    const ok = try req(&s, .GET, "/pursuits", "");
    defer testing.allocator.free(ok.body);
    try testing.expect(ok.allow == null);
}

test "acceptance: create ignores client-supplied read-only fields" {
    const path = "/tmp/tt-acc-readonly.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // Client tries to dictate id and completed_at; the server must ignore both.
    const c = try req(&s, .POST, "/pursuits",
        \\{"id":"hacker","completed_at":"2000-01-01T00:00:00Z","name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer testing.allocator.free(c.body);
    try testing.expectEqual(std.http.Status.created, c.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, c.body, .{});
    defer parsed.deinit();
    // Server-generated id, not the injected one.
    try testing.expect(!std.mem.eql(u8, parsed.value.object.get("id").?.string, "hacker"));
    // completed_at is not honored for a non-completed pursuit.
    try testing.expect(parsed.value.object.get("completed_at") == null);
}

test "acceptance: mutation returns 500 when persistence fails" {
    const path = "/tmp/training-tracker-missing-parent-dir/tt-acc-persist-fail.json";
    var s = try Store.init(testing.allocator, testIo(), path);
    defer s.deinit();

    const r = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer testing.allocator.free(r.body);

    try testing.expectEqual(std.http.Status.internal_server_error, r.status);
    const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 500), parsed.value.object.get("status").?.integer);
    try testing.expectEqualStrings("Failed to persist change", parsed.value.object.get("message").?.string);
}

test "non-pursuit path returns null (falls through to other routes)" {
    const path = "/tmp/tt-acc-null.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};
    try testing.expect((try handle(testing.allocator, &s, .GET, "/health", "")) == null);
}

test "Route.parse classifies the four shapes" {
    try testing.expectEqual(RouteKind.collection, Route.parse("/pursuits").kind);
    try testing.expectEqual(RouteKind.item, Route.parse("/pursuits/p_1").kind);
    try testing.expectEqual(RouteKind.milestones, Route.parse("/pursuits/p_1/milestones").kind);
    try testing.expectEqual(RouteKind.milestone_item, Route.parse("/pursuits/p_1/milestones/m_1").kind);
}

test "acceptance: GET /pursuits rejects an invalid limit query value with 400" {
    const path = "/tmp/tt-acc-query-limit.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // The contract says 1 <= limit <= 100 — no clamping.
    for ([_][]const u8{ "/pursuits?limit=0", "/pursuits?limit=101", "/pursuits?limit=ten", "/pursuits?limit=" }) |target| {
        const r = try req(&s, .GET, target, "");
        defer testing.allocator.free(r.body);
        try testing.expectEqual(std.http.Status.bad_request, r.status);

        const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("Invalid query parameter", parsed.value.object.get("message").?.string);
        try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("details").?.string, "'limit'") != null);
    }
}

test "acceptance: GET /pursuits rejects an invalid offset query value with 400" {
    const path = "/tmp/tt-acc-query-offset.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    for ([_][]const u8{ "/pursuits?offset=-1", "/pursuits?offset=x", "/pursuits?offset=" }) |target| {
        const r = try req(&s, .GET, target, "");
        defer testing.allocator.free(r.body);
        try testing.expectEqual(std.http.Status.bad_request, r.status);

        const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
        defer parsed.deinit();
        try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("details").?.string, "'offset'") != null);
    }
}

test "acceptance: GET /pursuits rejects an unknown type query value with 400" {
    const path = "/tmp/tt-acc-query-type.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    for ([_][]const u8{ "/pursuits?type=nope", "/pursuits?type=" }) |target| {
        const r = try req(&s, .GET, target, "");
        defer testing.allocator.free(r.body);
        try testing.expectEqual(std.http.Status.bad_request, r.status);

        const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
        defer parsed.deinit();
        try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("details").?.string, "'type'") != null);
    }
}

test "acceptance: GET /pursuits percent-decodes query values and ignores unknown keys" {
    const path = "/tmp/tt-acc-query-decode.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const c1 = try req(&s, .POST, "/pursuits",
        \\{"name":"a","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    testing.allocator.free(c1.body);
    const c2 = try req(&s, .POST, "/pursuits",
        \\{"name":"b","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    testing.allocator.free(c2.body);

    // "%63ertification" -> "certification", "%31%30" -> "10"; `sort` is not a contract parameter.
    const r = try req(&s, .GET, "/pursuits?type=%63ertification&limit=%31%30&sort=name", "");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.ok, r.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 10), parsed.value.object.get("limit").?.integer);
}

test "acceptance: 400 responses carry details naming the failing field" {
    const path = "/tmp/tt-acc-details.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // Store validation: the missing field is named.
    const missing = try req(&s, .POST, "/pursuits", "{\"type\":\"training\"}");
    defer testing.allocator.free(missing.body);
    try testing.expectEqual(std.http.Status.bad_request, missing.status);
    const mp = try json.parseFromSlice(Value, testing.allocator, missing.body, .{});
    defer mp.deinit();
    try testing.expectEqualStrings("Invalid request body", mp.value.object.get("message").?.string);
    try testing.expectEqualStrings("Field 'name' is required", mp.value.object.get("details").?.string);

    // Enum validation on PATCH: the allowed values are listed, as in the spec example.
    const c = try req(&s, .POST, "/pursuits",
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const cp = try json.parseFromSlice(Value, testing.allocator, c.body, .{});
    testing.allocator.free(c.body);
    const id = try testing.allocator.dupe(u8, cp.value.object.get("id").?.string);
    cp.deinit();
    defer testing.allocator.free(id);
    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);

    const bad_status = try req(&s, .PATCH, target, "{\"status\":\"done\"}");
    defer testing.allocator.free(bad_status.body);
    try testing.expectEqual(std.http.Status.bad_request, bad_status.status);
    const bp = try json.parseFromSlice(Value, testing.allocator, bad_status.body, .{});
    defer bp.deinit();
    try testing.expectEqualStrings(
        "Field 'status' must be one of: planned, in_progress, completed, expired",
        bp.value.object.get("details").?.string,
    );

    // Malformed JSON is reported as such rather than as a field error.
    const bad_json = try req(&s, .POST, "/pursuits", "{not json");
    defer testing.allocator.free(bad_json.body);
    try testing.expectEqual(std.http.Status.bad_request, bad_json.status);
    const jp = try json.parseFromSlice(Value, testing.allocator, bad_json.body, .{});
    defer jp.deinit();
    try testing.expectEqualStrings("Invalid JSON body", jp.value.object.get("message").?.string);
    try testing.expect(std.mem.startsWith(u8, jp.value.object.get("details").?.string, "Request body is not valid JSON"));
}

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
            else => try errorResponse(gpa, .method_not_allowed, "Method not allowed", null),
        },
        .item => switch (method) {
            .GET => try getPursuit(gpa, s, route.id.?),
            .PATCH => try updatePursuit(gpa, s, route.id.?, body),
            .DELETE => try deletePursuit(gpa, s, route.id.?),
            else => try errorResponse(gpa, .method_not_allowed, "Method not allowed", null),
        },
        .milestones => switch (method) {
            .POST => try createMilestone(gpa, s, route.id.?, body),
            else => try errorResponse(gpa, .method_not_allowed, "Method not allowed", null),
        },
        .milestone_item => switch (method) {
            .PATCH => try updateMilestone(gpa, s, route.id.?, route.milestone_id.?, body),
            .DELETE => try deleteMilestone(gpa, s, route.id.?, route.milestone_id.?),
            else => try errorResponse(gpa, .method_not_allowed, "Method not allowed", null),
        },
        .none => null,
    };
}

// ---- Operations ----------------------------------------------------------

fn listPursuits(gpa: Allocator, s: *Store, query: []const u8) Allocator.Error!Response {
    var limit: usize = 50;
    var offset: usize = 0;
    var type_filter: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "limit")) {
            const parsed = std.fmt.parseInt(usize, val, 10) catch continue;
            limit = std.math.clamp(parsed, 1, 100);
        } else if (std.mem.eql(u8, key, "offset")) {
            offset = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "type")) {
            type_filter = val;
        }
    }

    // Request-scoped arena: owns both the store's transient `matched` array and
    // the response envelope, all freed when this handler returns.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const res = s.list(a, type_filter, limit, offset) catch return oomRaw(gpa);

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

    const created = s.create(parsed.value) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .created, created);
}

fn getPursuit(gpa: Allocator, s: *Store, id: []const u8) Allocator.Error!Response {
    const p = s.get(id) catch |err| return mapStoreError(gpa, err);
    return jsonResponse(gpa, .ok, p);
}

fn updatePursuit(gpa: Allocator, s: *Store, id: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const updated = s.update(id, parsed.value) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .ok, updated);
}

fn deletePursuit(gpa: Allocator, s: *Store, id: []const u8) Allocator.Error!Response {
    s.delete(id) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return .{ .status = .no_content, .body = "" };
}

fn createMilestone(gpa: Allocator, s: *Store, pid: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const m = s.createMilestone(pid, parsed.value) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .created, m);
}

fn updateMilestone(gpa: Allocator, s: *Store, pid: []const u8, mid: []const u8, body: []const u8) Allocator.Error!Response {
    const parsed = switch (try parseBodyOr400(gpa, body)) {
        .ok => |p| p,
        .err => |r| return r,
    };
    defer parsed.deinit();

    const m = s.updateMilestone(pid, mid, parsed.value) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return jsonResponse(gpa, .ok, m);
}

fn deleteMilestone(gpa: Allocator, s: *Store, pid: []const u8, mid: []const u8) Allocator.Error!Response {
    s.deleteMilestone(pid, mid) catch |err| return mapStoreError(gpa, err);
    if (try persistOr500(gpa, s)) |r| return r;
    return .{ .status = .no_content, .body = "" };
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
    } else |_| {
        return .{ .err = try errorResponse(gpa, .bad_request, "Invalid JSON body", null) };
    }
}

fn jsonResponse(gpa: Allocator, status: std.http.Status, value: Value) Allocator.Error!Response {
    const bytes = json.Stringify.valueAlloc(gpa, value, .{}) catch return oomRaw(gpa);
    return .{ .status = status, .body = bytes };
}

const StoreOrOom = StoreError || Allocator.Error;

fn mapStoreError(gpa: Allocator, err: StoreOrOom) Allocator.Error!Response {
    log.debug("store rejected request: {s}", .{@errorName(err)});
    return switch (err) {
        error.Invalid => errorResponse(gpa, .bad_request, "Invalid request body", null),
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

test "acceptance: unsupported methods return 405" {
    const path = "/tmp/tt-acc-405.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // Collection allows only GET/POST.
    const c = try req(&s, .PUT, "/pursuits", "");
    defer testing.allocator.free(c.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, c.status);

    // Item allows only GET/PATCH/DELETE (405 is decided before existence).
    const i = try req(&s, .POST, "/pursuits/p_1", "");
    defer testing.allocator.free(i.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, i.status);

    // Milestones collection allows only POST.
    const m = try req(&s, .GET, "/pursuits/p_1/milestones", "");
    defer testing.allocator.free(m.body);
    try testing.expectEqual(std.http.Status.method_not_allowed, m.status);
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

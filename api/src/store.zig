//! Pursuit/Milestone domain logic + JSON-file persistence.
//!
//! The entire backend state lives in a single JSON file (`api/data.json`) shaped
//! as `{ "pursuits": [ ... ], "seq": <int> }`. The store reads the whole file,
//! mutates an in-memory `std.json.Value` tree, and writes it back. Domain types
//! are kept as `std.json.Value` objects so the on-disk shape matches the
//! OpenAPI schemas field-for-field without a parallel struct mapping.
//!
//! Validation rules come straight from `api/openapi.yaml` (the contract is law).

const std = @import("std");
const time_util = @import("time_util.zig");

const json = std.json;
const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const Array = json.Array;

const log = std.log.scoped(.store);

pub const max_name_len = 200;
pub const max_description_len = 2000;
pub const max_tag_len = 50;
pub const max_tags = 20;
pub const max_milestones = 50;

/// Domain-level validation / not-found errors. The handler maps these to the
/// HTTP status codes declared in the contract.
pub const StoreError = error{
    Invalid, // -> 400
    PursuitNotFound, // -> 404
    MilestoneNotFound, // -> 404
};

pub const ValidationError = error{Invalid};

/// In-memory store backed by a JSON file. Not thread-safe; the server handles
/// one request at a time per connection and this single-user app does not need
/// concurrency control yet.
pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    /// Arena owning the parsed document for the store's lifetime. Heap-allocated
    /// so its address is stable: the managed `Array`/`ObjectMap` values inside
    /// `root` capture this allocator's pointer, so the arena must not move.
    arena: *std.heap.ArenaAllocator,
    root: Value,
    seq: u64,

    pub fn init(gpa: Allocator, io: std.Io, path: []const u8) !Store {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const a = arena.allocator();
        var loaded_from_file = true;
        const root = readFile(a, io, path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                loaded_from_file = false;
                break :blk emptyRoot(a);
            },
            else => return err,
        };

        const seq: u64 = blk: {
            if (root == .object) {
                if (root.object.get("seq")) |v| {
                    if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
                }
            }
            break :blk 0;
        };

        if (loaded_from_file) {
            const count = if (root == .object)
                if (root.object.get("pursuits")) |p| (if (p == .array) p.array.items.len else 0) else 0
            else
                0;
            log.info("loaded {d} pursuit(s) from {s}", .{ count, path });
        } else {
            log.info("no data file at {s}; starting with an empty store", .{path});
        }

        return .{
            .gpa = gpa,
            .io = io,
            .path = path,
            .arena = arena,
            .root = root,
            .seq = seq,
        };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    fn alloc(self: *Store) Allocator {
        return self.arena.allocator();
    }

    fn pursuitsArray(self: *Store) *Array {
        return &self.root.object.getPtr("pursuits").?.array;
    }

    fn nextId(self: *Store, prefix: []const u8) ![]const u8 {
        self.seq += 1;
        const a = self.alloc();
        return std.fmt.allocPrint(a, "{s}{d}", .{ prefix, self.seq });
    }

    /// Persist the current in-memory tree back to disk via an atomic replace:
    /// write to a sibling `<path>.tmp` then rename it over the live file. POSIX
    /// rename is atomic, so a crash mid-write leaves the original file intact and
    /// readers never observe a partial document.
    pub fn flush(self: *Store) !void {
        // Keep seq in the document so IDs stay monotonic across restarts.
        try self.root.object.put(self.alloc(), "seq", .{ .integer = @intCast(self.seq) });

        const bytes = try json.Stringify.valueAlloc(self.gpa, self.root, .{ .whitespace = .indent_2 });
        defer self.gpa.free(bytes);

        const tmp_path = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{self.path});
        defer self.gpa.free(tmp_path);

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = tmp_path, .data = bytes });
        // If the rename fails, drop the temp file so no stale `.tmp` is left
        // behind; the live file is untouched either way.
        errdefer cwd.deleteFile(self.io, tmp_path) catch {};
        try cwd.rename(self.io, tmp_path, self.path);
    }

    // ---- Queries ---------------------------------------------------------

    pub const ListResult = struct {
        data: []Value,
        total: usize,
        limit: usize,
        offset: usize,
    };

    /// Returns a paginated (and optionally type-filtered) view of pursuits. The
    /// temporary `matched` array is allocated with the caller-supplied `gpa`
    /// (typically a per-request arena) so it does not leak into the store's
    /// lifetime arena. The returned `data` slice borrows that allocator and the
    /// pursuit Values (which live in the store arena), so it must be consumed
    /// before `gpa` is freed.
    pub fn list(self: *Store, gpa: Allocator, type_filter: ?[]const u8, limit: usize, offset: usize) !ListResult {
        const arr = self.pursuitsArray();
        const a = gpa;

        var matched: std.ArrayList(Value) = .empty;
        for (arr.items) |item| {
            if (type_filter) |t| {
                const it = item.object.get("type") orelse continue;
                if (it != .string or !std.mem.eql(u8, it.string, t)) continue;
            }
            try matched.append(a, item);
        }

        const total = matched.items.len;
        const start = @min(offset, total);
        const end = @min(start + limit, total);
        return .{
            .data = matched.items[start..end],
            .total = total,
            .limit = limit,
            .offset = offset,
        };
    }

    fn findPursuitIndex(self: *Store, id: []const u8) ?usize {
        const arr = self.pursuitsArray();
        for (arr.items, 0..) |item, i| {
            const pid = item.object.get("id") orelse continue;
            if (pid == .string and std.mem.eql(u8, pid.string, id)) return i;
        }
        return null;
    }

    pub fn get(self: *Store, id: []const u8) StoreError!Value {
        const idx = self.findPursuitIndex(id) orelse return StoreError.PursuitNotFound;
        return self.pursuitsArray().items[idx];
    }

    // ---- Mutations -------------------------------------------------------

    /// Create a pursuit from a parsed request body (`PursuitCreate`). Returns
    /// the created `Pursuit` value (arena-owned). Caller flushes.
    pub fn create(self: *Store, body: Value) (StoreError || Allocator.Error)!Value {
        const a = self.alloc();
        if (body != .object) return StoreError.Invalid;
        const in = body.object;

        const name = try requireString(in, "name", 1, max_name_len);
        const ptype = try requireEnum(in, "type", &pursuit_types);
        const target_date = try requireDateTime(in, "target_date");
        const started_at = try requireDateTime(in, "started_at");

        // status defaults to "planned"
        const status = try optionalEnum(in, "status", &statuses) orelse "planned";

        var obj = ObjectMap{};
        const id = try self.nextId("p_");
        try obj.put(a, "id", .{ .string = id });
        try obj.put(a, "name", .{ .string = try a.dupe(u8, name) });
        try obj.put(a, "type", .{ .string = ptype });
        try obj.put(a, "status", .{ .string = status });

        if (try optionalString(in, "description", 0, max_description_len)) |d|
            try obj.put(a, "description", .{ .string = try a.dupe(u8, d) });

        try obj.put(a, "target_date", .{ .string = try a.dupe(u8, target_date) });
        try obj.put(a, "started_at", .{ .string = try a.dupe(u8, started_at) });

        if (try optionalDateTime(in, "expires_at")) |e|
            try obj.put(a, "expires_at", .{ .string = try a.dupe(u8, e) });

        // Auto-set completed_at when created already completed.
        if (std.mem.eql(u8, status, "completed"))
            try obj.put(a, "completed_at", .{ .string = try self.stampNow() });

        try obj.put(a, "tags", .{ .array = try self.parseTags(in) });
        try obj.put(a, "milestones", .{ .array = try self.parseInlineMilestones(in) });

        try self.pursuitsArray().append(.{ .object = obj });
        return .{ .object = obj };
    }

    /// Apply a partial update (`PursuitUpdate`). Read-only fields (id,
    /// completed_at) are ignored. Returns the updated pursuit.
    pub fn update(self: *Store, id: []const u8, body: Value) (StoreError || Allocator.Error)!Value {
        const idx = self.findPursuitIndex(id) orelse return StoreError.PursuitNotFound;
        const a = self.alloc();
        if (body != .object) return StoreError.Invalid;
        const in = body.object;

        var obj = &self.pursuitsArray().items[idx].object;

        if (try optionalString(in, "name", 1, max_name_len)) |v|
            try obj.put(a, "name", .{ .string = try a.dupe(u8, v) });
        if (try optionalEnum(in, "type", &pursuit_types)) |v|
            try obj.put(a, "type", .{ .string = v });
        if (try optionalString(in, "description", 0, max_description_len)) |v|
            try obj.put(a, "description", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(in, "target_date")) |v|
            try obj.put(a, "target_date", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(in, "started_at")) |v|
            try obj.put(a, "started_at", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(in, "expires_at")) |v|
            try obj.put(a, "expires_at", .{ .string = try a.dupe(u8, v) });

        if (in.get("tags")) |_|
            try obj.put(a, "tags", .{ .array = try self.parseTags(in) });

        if (try optionalEnum(in, "status", &statuses)) |new_status| {
            const prev = obj.get("status");
            const was_completed = prev != null and prev.? == .string and
                std.mem.eql(u8, prev.?.string, "completed");
            try obj.put(a, "status", .{ .string = new_status });
            if (std.mem.eql(u8, new_status, "completed") and !was_completed) {
                try obj.put(a, "completed_at", .{ .string = try self.stampNow() });
            }
        }

        return self.pursuitsArray().items[idx];
    }

    pub fn delete(self: *Store, id: []const u8) StoreError!void {
        const idx = self.findPursuitIndex(id) orelse return StoreError.PursuitNotFound;
        _ = self.pursuitsArray().orderedRemove(idx);
    }

    // ---- Milestone mutations --------------------------------------------

    fn milestonesArray(self: *Store, pidx: usize) *Array {
        return &self.pursuitsArray().items[pidx].object.getPtr("milestones").?.array;
    }

    fn findMilestoneIndex(self: *Store, pidx: usize, mid: []const u8) ?usize {
        const arr = self.milestonesArray(pidx);
        for (arr.items, 0..) |item, i| {
            const id = item.object.get("id") orelse continue;
            if (id == .string and std.mem.eql(u8, id.string, mid)) return i;
        }
        return null;
    }

    pub fn createMilestone(self: *Store, pursuit_id: []const u8, body: Value) (StoreError || Allocator.Error)!Value {
        const pidx = self.findPursuitIndex(pursuit_id) orelse return StoreError.PursuitNotFound;
        const a = self.alloc();
        if (body != .object) return StoreError.Invalid;
        const in = body.object;

        const name = try requireString(in, "name", 1, max_name_len);
        const date = try requireDateTime(in, "date");
        const state = try optionalEnum(in, "state", &milestone_states) orelse "pending";

        const arr = self.milestonesArray(pidx);
        if (arr.items.len >= max_milestones) return StoreError.Invalid;

        var obj = ObjectMap{};
        const id = try self.nextId("m_");
        try obj.put(a, "id", .{ .string = id });
        try obj.put(a, "name", .{ .string = try a.dupe(u8, name) });
        try obj.put(a, "date", .{ .string = try a.dupe(u8, date) });
        try obj.put(a, "state", .{ .string = state });
        if (std.mem.eql(u8, state, "achieved"))
            try obj.put(a, "achieved_at", .{ .string = try self.stampNow() });

        try arr.append(.{ .object = obj });
        return .{ .object = obj };
    }

    pub fn updateMilestone(
        self: *Store,
        pursuit_id: []const u8,
        milestone_id: []const u8,
        body: Value,
    ) (StoreError || Allocator.Error)!Value {
        const pidx = self.findPursuitIndex(pursuit_id) orelse return StoreError.PursuitNotFound;
        const midx = self.findMilestoneIndex(pidx, milestone_id) orelse return StoreError.MilestoneNotFound;
        const a = self.alloc();
        if (body != .object) return StoreError.Invalid;
        const in = body.object;

        var obj = &self.milestonesArray(pidx).items[midx].object;

        if (try optionalString(in, "name", 1, max_name_len)) |v|
            try obj.put(a, "name", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(in, "date")) |v|
            try obj.put(a, "date", .{ .string = try a.dupe(u8, v) });

        if (try optionalEnum(in, "state", &milestone_states)) |new_state| {
            try obj.put(a, "state", .{ .string = new_state });
            if (std.mem.eql(u8, new_state, "achieved")) {
                if (obj.get("achieved_at") == null)
                    try obj.put(a, "achieved_at", .{ .string = try self.stampNow() });
            } else {
                // Toggling back to pending clears achieved_at.
                _ = obj.swapRemove("achieved_at");
            }
        }

        return self.milestonesArray(pidx).items[midx];
    }

    pub fn deleteMilestone(self: *Store, pursuit_id: []const u8, milestone_id: []const u8) StoreError!void {
        const pidx = self.findPursuitIndex(pursuit_id) orelse return StoreError.PursuitNotFound;
        const midx = self.findMilestoneIndex(pidx, milestone_id) orelse return StoreError.MilestoneNotFound;
        _ = self.milestonesArray(pidx).orderedRemove(midx);
    }

    // ---- Helpers ---------------------------------------------------------

    fn stampNow(self: *Store) ![]const u8 {
        const a = self.alloc();
        var buf: [32]u8 = undefined;
        const s = time_util.nowIso8601(self.io, &buf);
        return a.dupe(u8, s);
    }

    fn parseTags(self: *Store, in: ObjectMap) !Array {
        const a = self.alloc();
        var out = Array.init(a);
        const tags_val = in.get("tags") orelse return out;
        if (tags_val != .array) return StoreError.Invalid;
        if (tags_val.array.items.len > max_tags) return StoreError.Invalid;
        for (tags_val.array.items) |t| {
            if (t != .string) return StoreError.Invalid;
            if (t.string.len < 1 or t.string.len > max_tag_len) return StoreError.Invalid;
            try out.append(.{ .string = try a.dupe(u8, t.string) });
        }
        return out;
    }

    fn parseInlineMilestones(self: *Store, in: ObjectMap) !Array {
        const a = self.alloc();
        var out = Array.init(a);
        const ms_val = in.get("milestones") orelse return out;
        if (ms_val != .array) return StoreError.Invalid;
        if (ms_val.array.items.len > max_milestones) return StoreError.Invalid;
        for (ms_val.array.items) |m| {
            if (m != .object) return StoreError.Invalid;
            const mo = m.object;
            const name = try requireString(mo, "name", 1, max_name_len);
            const date = try requireDateTime(mo, "date");
            const state = try optionalEnum(mo, "state", &milestone_states) orelse "pending";

            var obj = ObjectMap{};
            try obj.put(a, "id", .{ .string = try self.nextId("m_") });
            try obj.put(a, "name", .{ .string = try a.dupe(u8, name) });
            try obj.put(a, "date", .{ .string = try a.dupe(u8, date) });
            try obj.put(a, "state", .{ .string = state });
            if (std.mem.eql(u8, state, "achieved"))
                try obj.put(a, "achieved_at", .{ .string = try self.stampNow() });
            try out.append(.{ .object = obj });
        }
        return out;
    }
};

// ---- Enum tables (mirror the OpenAPI enums) -----------------------------

const pursuit_types = [_][]const u8{ "certification", "training" };
const statuses = [_][]const u8{ "planned", "in_progress", "completed", "expired" };
const milestone_states = [_][]const u8{ "pending", "achieved" };

// ---- Field validation helpers -------------------------------------------

fn requireString(obj: ObjectMap, key: []const u8, min_len: usize, max_len: usize) ValidationError![]const u8 {
    const v = obj.get(key) orelse return error.Invalid;
    if (v != .string) return error.Invalid;
    if (v.string.len < min_len or v.string.len > max_len) return error.Invalid;
    return v.string;
}

fn optionalString(obj: ObjectMap, key: []const u8, min_len: usize, max_len: usize) ValidationError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return error.Invalid;
    if (v.string.len < min_len or v.string.len > max_len) return error.Invalid;
    return v.string;
}

/// Like `requireString`, but additionally enforces the OpenAPI `date-time`
/// contract (ISO 8601 UTC) on the value.
fn requireDateTime(obj: ObjectMap, key: []const u8) ValidationError![]const u8 {
    const v = try requireString(obj, key, 1, std.math.maxInt(usize));
    if (!time_util.isIso8601(v)) return error.Invalid;
    return v;
}

/// Like `optionalString`, but enforces `date-time` when the field is present.
fn optionalDateTime(obj: ObjectMap, key: []const u8) ValidationError!?[]const u8 {
    const v = (try optionalString(obj, key, 1, std.math.maxInt(usize))) orelse return null;
    if (!time_util.isIso8601(v)) return error.Invalid;
    return v;
}

fn requireEnum(obj: ObjectMap, key: []const u8, allowed: []const []const u8) ValidationError![]const u8 {
    const v = obj.get(key) orelse return error.Invalid;
    return matchEnum(v, allowed) orelse error.Invalid;
}

fn optionalEnum(obj: ObjectMap, key: []const u8, allowed: []const []const u8) ValidationError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return matchEnum(v, allowed) orelse error.Invalid;
}

fn matchEnum(v: Value, allowed: []const []const u8) ?[]const u8 {
    if (v != .string) return null;
    for (allowed) |a| {
        if (std.mem.eql(u8, v.string, a)) return a;
    }
    return null;
}

// ---- File IO ------------------------------------------------------------

fn emptyRoot(a: Allocator) Value {
    var obj = ObjectMap{};
    obj.put(a, "pursuits", .{ .array = Array.init(a) }) catch unreachable;
    obj.put(a, "seq", .{ .integer = 0 }) catch unreachable;
    return .{ .object = obj };
}

fn readFile(a: Allocator, io: std.Io, path: []const u8) !Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, std.Io.Limit.limited(16 * 1024 * 1024));
    const parsed = try json.parseFromSliceLeaky(Value, a, bytes, .{});
    if (parsed != .object) return emptyRoot(a);
    if (parsed.object.get("pursuits") == null) {
        var obj = parsed.object;
        try obj.put(a, "pursuits", .{ .array = Array.init(a) });
        return .{ .object = obj };
    }
    return parsed;
}

// =========================================================================
// Unit tests
// =========================================================================

const testing = std.testing;

fn parse(a: Allocator, s: []const u8) !Value {
    return json.parseFromSliceLeaky(Value, a, s, .{});
}

// A process-wide threaded Io for tests that need real file IO.
var test_threaded: ?std.Io.Threaded = null;

fn testIo() std.Io {
    if (test_threaded == null) {
        test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return test_threaded.?.io();
}

fn testStore(a: Allocator) !Store {
    // Unit tests that never flush still need a (missing) path -> empty store.
    return Store.init(a, testIo(), "/tmp/training-tracker-nonexistent-unit-data.json");
}

test "create assigns id, defaults status to planned, and persists in list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try testStore(testing.allocator);
    defer s.deinit();

    const body = try parse(a,
        \\{"name":"AWS SAA","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const created = try s.create(body);
    try testing.expect(created.object.get("id").?.string.len > 0);
    try testing.expectEqualStrings("planned", created.object.get("status").?.string);
    try testing.expectEqual(@as(usize, 0), created.object.get("milestones").?.array.items.len);

    const res = try s.list(a, null, 50, 0);
    try testing.expectEqual(@as(usize, 1), res.total);
}

test "create with status completed auto-sets completed_at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const body = try parse(a,
        \\{"name":"Done","type":"training","status":"completed","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    const created = try s.create(body);
    try testing.expect(created.object.get("completed_at") != null);
}

test "create rejects missing required fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const body = try parse(a, "{\"type\":\"training\"}");
    try testing.expectError(StoreError.Invalid, s.create(body));
}

test "create rejects invalid enum and over-length name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const bad_type = try parse(a,
        \\{"name":"n","type":"nope","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    try testing.expectError(StoreError.Invalid, s.create(bad_type));

    var long_buf: [260]u8 = undefined;
    @memset(&long_buf, 'a');
    const long = try std.fmt.allocPrint(a,
        \\{{"name":"{s}","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}}
    , .{long_buf[0..210]});
    const long_body = try parse(a, long);
    try testing.expectError(StoreError.Invalid, s.create(long_body));
}

test "get returns not found for unknown id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try testStore(testing.allocator);
    defer s.deinit();
    try testing.expectError(StoreError.PursuitNotFound, s.get("nope"));
}

test "update applies partial changes and sets completed_at on transition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const created = try s.create(try parse(a,
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    ));
    const id = created.object.get("id").?.string;

    const updated = try s.update(id, try parse(a,
        \\{"name":"Y","status":"completed"}
    ));
    try testing.expectEqualStrings("Y", updated.object.get("name").?.string);
    try testing.expectEqualStrings("completed", updated.object.get("status").?.string);
    try testing.expect(updated.object.get("completed_at") != null);
}

test "update on missing pursuit returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();
    try testing.expectError(StoreError.PursuitNotFound, s.update("nope", try parse(a, "{}")));
}

test "delete removes the pursuit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();
    const created = try s.create(try parse(a,
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    ));
    const id = try a.dupe(u8, created.object.get("id").?.string);
    try s.delete(id);
    try testing.expectError(StoreError.PursuitNotFound, s.get(id));
    try testing.expectError(StoreError.PursuitNotFound, s.delete(id));
}

test "list filters by type and paginates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    _ = try s.create(try parse(a, "{\"name\":\"a\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    _ = try s.create(try parse(a, "{\"name\":\"b\",\"type\":\"certification\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    _ = try s.create(try parse(a, "{\"name\":\"c\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));

    const trainings = try s.list(a, "training", 50, 0);
    try testing.expectEqual(@as(usize, 2), trainings.total);

    const page = try s.list(a, null, 1, 1);
    try testing.expectEqual(@as(usize, 3), page.total);
    try testing.expectEqual(@as(usize, 1), page.data.len);
}

test "createMilestone assigns id and auto-sets achieved_at when achieved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const created = try s.create(try parse(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    const id = try a.dupe(u8, created.object.get("id").?.string);

    const m = try s.createMilestone(id, try parse(a,
        \\{"name":"Exam","date":"2026-07-15T00:00:00Z","state":"achieved"}
    ));
    try testing.expect(m.object.get("id").?.string.len > 0);
    try testing.expect(m.object.get("achieved_at") != null);

    const got = try s.get(id);
    try testing.expectEqual(@as(usize, 1), got.object.get("milestones").?.array.items.len);
}

test "createMilestone on missing pursuit returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();
    try testing.expectError(StoreError.PursuitNotFound, s.createMilestone("nope", try parse(a,
        \\{"name":"E","date":"2026-07-15T00:00:00Z"}
    )));
}

test "updateMilestone toggling achieved->pending clears achieved_at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const created = try s.create(try parse(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    const pid = try a.dupe(u8, created.object.get("id").?.string);
    const m = try s.createMilestone(pid, try parse(a,
        \\{"name":"E","date":"2026-07-15T00:00:00Z","state":"achieved"}
    ));
    const mid = try a.dupe(u8, m.object.get("id").?.string);
    try testing.expect((try s.get(pid)).object.get("milestones").?.array.items[0].object.get("achieved_at") != null);

    const updated = try s.updateMilestone(pid, mid, try parse(a, "{\"state\":\"pending\"}"));
    try testing.expect(updated.object.get("achieved_at") == null);
}

test "deleteMilestone removes it; unknown milestone is not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const created = try s.create(try parse(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    const pid = try a.dupe(u8, created.object.get("id").?.string);
    const m = try s.createMilestone(pid, try parse(a, "{\"name\":\"E\",\"date\":\"2026-07-15T00:00:00Z\"}"));
    const mid = try a.dupe(u8, m.object.get("id").?.string);

    try testing.expectError(StoreError.MilestoneNotFound, s.deleteMilestone(pid, "nope"));
    try s.deleteMilestone(pid, mid);
    try testing.expectEqual(@as(usize, 0), (try s.get(pid)).object.get("milestones").?.array.items.len);
}

test "tags over the limit are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\",\"tags\":[");
    for (0..21) |i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.appendSlice(a, "\"t\"");
    }
    try buf.appendSlice(a, "]}");
    try testing.expectError(StoreError.Invalid, s.create(try parse(a, buf.items)));
}

test "flush writes and reload preserves seq and data" {
    const io = testIo();
    const path = "/tmp/training-tracker-flush-test.json";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var s = try Store.init(testing.allocator, io, path);
        defer s.deinit();
        _ = try s.create(try parse(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
        try s.flush();
    }

    var s2 = try Store.init(testing.allocator, io, path);
    defer s2.deinit();
    const res = try s2.list(a, null, 50, 0);
    try testing.expectEqual(@as(usize, 1), res.total);
    // New IDs continue from persisted seq (no collision with p_1).
    const created2 = try s2.create(try parse(a, "{\"name\":\"Y\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    try testing.expect(!std.mem.eql(u8, created2.object.get("id").?.string, "p_1"));
}

test "flush leaves no temp file and round-trips after reload" {
    const io = testIo();
    const path = "/tmp/training-tracker-durability-test.json";
    const tmp_path = path ++ ".tmp";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var s = try Store.init(testing.allocator, io, path);
        defer s.deinit();
        _ = try s.create(try parse(a, "{\"name\":\"Durable\",\"type\":\"certification\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
        try s.flush();
    }

    // The atomic rename must not leave the temp file behind.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, tmp_path, a, std.Io.Limit.limited(1024)));

    // A fresh reload round-trips the persisted data.
    var s2 = try Store.init(testing.allocator, io, path);
    defer s2.deinit();
    const res = try s2.list(a, null, 50, 0);
    try testing.expectEqual(@as(usize, 1), res.total);
    try testing.expectEqualStrings("Durable", res.data[0].object.get("name").?.string);
}

test "create rejects malformed date-time fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const bad_target = try parse(a,
        \\{"name":"n","type":"training","target_date":"x","started_at":"2026-06-01T00:00:00Z"}
    );
    try testing.expectError(StoreError.Invalid, s.create(bad_target));

    const bad_started = try parse(a,
        \\{"name":"n","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"nope"}
    );
    try testing.expectError(StoreError.Invalid, s.create(bad_started));

    const bad_expires = try parse(a,
        \\{"name":"n","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","expires_at":"2026-13-01T00:00:00Z"}
    );
    try testing.expectError(StoreError.Invalid, s.create(bad_expires));
}

test "createMilestone rejects malformed date" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const created = try s.create(try parse(a, "{\"name\":\"X\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}"));
    const id = try a.dupe(u8, created.object.get("id").?.string);
    try testing.expectError(StoreError.Invalid, s.createMilestone(id, try parse(a,
        \\{"name":"Exam","date":"someday"}
    )));
}

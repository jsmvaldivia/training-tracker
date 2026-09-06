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
    Conflict, // -> 409: a valid request the resource's current state forbids
    PursuitNotFound, // -> 404
    MilestoneNotFound, // -> 404
};

pub const ValidationError = error{Invalid};

/// Why the most recent validation failed, worded like the contract's
/// `Error.details` examples ("Field 'name' is required"). Zig errors carry no
/// payload, so the validators write the reason here and the handler reads it
/// back when it maps `error.Invalid` to a 400. Every mutation resets it first;
/// the store is single-threaded, so one slot is enough.
pub const Diag = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            // Truncated: keep what fits rather than lose the message.
            self.len = self.buf.len;
            return;
        };
        self.len = out.len;
    }

    fn reset(self: *Diag) void {
        self.len = 0;
    }

    /// The message for the last `error.Invalid`, or null when the last
    /// mutation succeeded.
    pub fn message(self: *const Diag) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

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
    /// Reason for the last validation failure; see `Diag`.
    diag: Diag = .{},

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

    /// Discards the in-memory tree and re-reads the file. The handler calls
    /// this after a failed `flush` so a 500 never leaves memory ahead of disk:
    /// the client rolled back on the 500, and a later successful flush would
    /// otherwise persist the rejected change behind its back.
    pub fn reload(self: *Store) !void {
        const fresh = try Store.init(self.gpa, self.io, self.path);
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.arena = fresh.arena;
        self.root = fresh.root;
        self.seq = fresh.seq;
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

    /// Persist the current in-memory tree back to disk.
    ///
    /// Writes to a sibling temp file and then atomically `rename`s it over the
    /// target. POSIX rename is atomic, so a crash, power loss, or ENOSPC partway
    /// through can never leave a torn `data.json` — a reader always sees either
    /// the complete old file or the complete new one. This file is the sole
    /// source of truth, so a non-atomic write would risk total data loss.
    pub fn flush(self: *Store) !void {
        // Keep seq in the document so IDs stay monotonic across restarts.
        try self.root.object.put(self.alloc(), "seq", .{ .integer = @intCast(self.seq) });

        const bytes = try json.Stringify.valueAlloc(self.gpa, self.root, .{ .whitespace = .indent_2 });
        defer self.gpa.free(bytes);

        // Per-process temp name so concurrent writers (e.g. parallel test
        // binaries sharing a data path) never race on the same temp file before
        // the rename. In production only one server writes, so the pid is
        // simply a uniqueness belt-and-suspenders.
        const tmp_path = try std.fmt.allocPrint(self.gpa, "{s}.{d}.tmp", .{ self.path, std.c.getpid() });
        defer self.gpa.free(tmp_path);

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = tmp_path, .data = bytes });
        errdefer cwd.deleteFile(self.io, tmp_path) catch {};
        try cwd.rename(tmp_path, cwd, self.path, self.io);
    }

    // ---- Queries ---------------------------------------------------------

    pub const ListResult = struct {
        data: []Value,
        total: usize,
        limit: usize,
        offset: usize,
    };

    /// Returns a paginated (and optionally type-filtered) view of pursuits.
    ///
    /// The transient `matched` array is allocated from the caller-supplied
    /// `scratch` allocator (use a request-scoped arena that is freed after the
    /// response) rather than the store's lifetime arena — otherwise every GET
    /// would leak its working set for the life of the process. The returned
    /// `Value`s themselves still borrow from the store's arena (they are not
    /// copied), so the slice is valid until the next mutation.
    ///
    /// Note: mutation churn (repeated create/update) still accumulates in the
    /// store arena; that is a known, bounded limitation the SQLite migration
    /// resolves.
    pub fn list(self: *Store, scratch: Allocator, type_filter: ?[]const u8, limit: usize, offset: usize) !ListResult {
        const arr = self.pursuitsArray();
        const a = scratch;

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
        const d = &self.diag;
        const in = try requireObject(d, body);

        const name = try requireString(d, in, "name", 1, max_name_len);
        const ptype = try requireEnum(d, in, "type", &pursuit_types);
        const target_date = try requireDateTime(d, in, "target_date");
        const started_at = try requireDateTime(d, in, "started_at");

        // status defaults to "planned"
        const status = try optionalEnum(d, in, "status", &statuses) orelse "planned";

        var obj = ObjectMap{};
        const id = try self.nextId("p_");
        try obj.put(a, "id", .{ .string = id });
        try obj.put(a, "name", .{ .string = try a.dupe(u8, name) });
        try obj.put(a, "type", .{ .string = ptype });
        try obj.put(a, "status", .{ .string = status });

        if (try optionalString(d, in, "description", 0, max_description_len)) |desc|
            try obj.put(a, "description", .{ .string = try a.dupe(u8, desc) });

        try obj.put(a, "target_date", .{ .string = try a.dupe(u8, target_date) });
        try obj.put(a, "started_at", .{ .string = try a.dupe(u8, started_at) });

        if (try optionalDateTime(d, in, "expires_at")) |e|
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
        const d = &self.diag;
        const in = try requireObject(d, body);

        var obj = &self.pursuitsArray().items[idx].object;

        if (try optionalString(d, in, "name", 1, max_name_len)) |v|
            try obj.put(a, "name", .{ .string = try a.dupe(u8, v) });
        if (try optionalEnum(d, in, "type", &pursuit_types)) |v|
            try obj.put(a, "type", .{ .string = v });
        if (try optionalString(d, in, "description", 0, max_description_len)) |v|
            try obj.put(a, "description", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(d, in, "target_date")) |v|
            try obj.put(a, "target_date", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(d, in, "started_at")) |v|
            try obj.put(a, "started_at", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(d, in, "expires_at")) |v|
            try obj.put(a, "expires_at", .{ .string = try a.dupe(u8, v) });

        if (in.get("tags")) |_|
            try obj.put(a, "tags", .{ .array = try self.parseTags(in) });

        if (try optionalEnum(d, in, "status", &statuses)) |new_status| {
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
        const d = &self.diag;
        const in = try requireObject(d, body);

        const name = try requireString(d, in, "name", 1, max_name_len);
        const date = try requireDateTime(d, in, "date");
        const state = try optionalEnum(d, in, "state", &milestone_states) orelse "pending";

        const arr = self.milestonesArray(pidx);
        if (arr.items.len >= max_milestones) {
            // The body is valid; the pursuit is full. That is a 409, not a 400.
            d.set("Pursuit already has the maximum of {d} milestones", .{max_milestones});
            return StoreError.Conflict;
        }

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
        const d = &self.diag;
        const in = try requireObject(d, body);

        var obj = &self.milestonesArray(pidx).items[midx].object;

        if (try optionalString(d, in, "name", 1, max_name_len)) |v|
            try obj.put(a, "name", .{ .string = try a.dupe(u8, v) });
        if (try optionalDateTime(d, in, "date")) |v|
            try obj.put(a, "date", .{ .string = try a.dupe(u8, v) });

        if (try optionalEnum(d, in, "state", &milestone_states)) |new_state| {
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

    // ---- Read-side view --------------------------------------------------

    /// The pursuit as the API reports it (issue #28): `status` replaced by
    /// `derivedStatus` when the two differ. The copy is shallow and lives in
    /// `scratch` (a request arena); the stored value is untouched, so a later
    /// flush never persists a derived status.
    pub fn present(self: *Store, scratch: Allocator, pursuit: Value) Allocator.Error!Value {
        var buf: [32]u8 = undefined;
        const now = time_util.nowIso8601(self.io, &buf);
        const shown = derivedStatus(pursuit.object, now);
        const stored = stringField(pursuit.object, "status") orelse "";
        if (std.mem.eql(u8, shown, stored)) return pursuit;
        var copy = try pursuit.object.clone(scratch);
        try copy.put(scratch, "status", .{ .string = shown });
        return .{ .object = copy };
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
        const d = &self.diag;
        var out = Array.init(a);
        const tags_val = in.get("tags") orelse return out;
        if (tags_val != .array or tags_val.array.items.len > max_tags) {
            d.set("Field 'tags' must be an array of at most {d} strings", .{max_tags});
            return StoreError.Invalid;
        }
        for (tags_val.array.items, 0..) |t, i| {
            if (t != .string or charCount(t.string) < 1 or charCount(t.string) > max_tag_len) {
                d.set("Field 'tags[{d}]' must be a string between 1 and {d} characters", .{ i, max_tag_len });
                return StoreError.Invalid;
            }
            try out.append(.{ .string = try a.dupe(u8, t.string) });
        }
        return out;
    }

    fn parseInlineMilestones(self: *Store, in: ObjectMap) !Array {
        const a = self.alloc();
        const d = &self.diag;
        var out = Array.init(a);
        const ms_val = in.get("milestones") orelse return out;
        if (ms_val != .array or ms_val.array.items.len > max_milestones) {
            d.set("Field 'milestones' must be an array of at most {d} milestones", .{max_milestones});
            return StoreError.Invalid;
        }
        for (ms_val.array.items, 0..) |m, i| {
            if (m != .object) {
                d.set("Field 'milestones[{d}]' must be an object", .{i});
                return StoreError.Invalid;
            }
            const mo = m.object;
            // A rejected inline milestone is reported by its path
            // (`milestones[2].date`) so the 400 is not mistaken for one on
            // the pursuit's own fields.
            const name = requireString(d, mo, "name", 1, max_name_len) catch |e| return nestDiag(d, i, e);
            const date = requireDateTime(d, mo, "date") catch |e| return nestDiag(d, i, e);
            const state = (optionalEnum(d, mo, "state", &milestone_states) catch |e| return nestDiag(d, i, e)) orelse "pending";

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

/// The status a pursuit reads as, given the clock (issue #28): a `completed`
/// pursuit whose `expires_at` has passed is `expired`. Any other stored status
/// stands — a pursuit never obtained cannot expire (it is overdue instead),
/// and `expired` set by hand is kept. Derived on every read and never stored,
/// so the file keeps the explicit lifecycle state and the rule can change
/// without a data migration. `now` is an ISO 8601 UTC timestamp.
pub fn derivedStatus(obj: ObjectMap, now: []const u8) []const u8 {
    const status = stringField(obj, "status") orelse "planned";
    if (!std.mem.eql(u8, status, "completed")) return status;
    const expires_at = stringField(obj, "expires_at") orelse return status;
    return if (hasPassed(expires_at, now)) "expired" else status;
}

/// True when `ts` is strictly before `now`. Both are validated ISO 8601 UTC
/// timestamps, whose first 19 characters (`YYYY-MM-DDThh:mm:ss`) order
/// lexicographically; fractional seconds are ignored, so the comparison is
/// to the second.
fn hasPassed(ts: []const u8, now: []const u8) bool {
    if (ts.len < 19 or now.len < 19) return false;
    return std.mem.order(u8, ts[0..19], now[0..19]) == .lt;
}

fn stringField(obj: ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// True when `s` is a `PursuitType` enum value from the contract. Used by the
/// handler to validate the `type` query filter with the same table the store
/// applies to request bodies.
pub fn isPursuitType(s: []const u8) bool {
    for (pursuit_types) |t| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

// ---- Field validation helpers -------------------------------------------
//
// Each helper writes the reason for a rejection into `d` right before it
// returns `error.Invalid`, so the handler can surface it as `Error.details`.

/// Rewrites a pending "Field 'x' ..." message into "Field 'milestones[i].x' ..."
/// and passes the error through, so inline-milestone rejections name their path.
fn nestDiag(d: *Diag, index: usize, err: ValidationError) ValidationError {
    const prefix = "Field '";
    if (d.message()) |msg| {
        if (std.mem.startsWith(u8, msg, prefix)) {
            var tmp: [192]u8 = undefined;
            const rest = msg[prefix.len..];
            if (std.fmt.bufPrint(&tmp, "{s}milestones[{d}].{s}", .{ prefix, index, rest })) |out| {
                d.set("{s}", .{out});
            } else |_| {}
        }
    }
    return err;
}

fn requireObject(d: *Diag, body: Value) ValidationError!ObjectMap {
    d.reset();
    if (body != .object) {
        d.set("Request body must be a JSON object", .{});
        return error.Invalid;
    }
    return body.object;
}

fn requireString(d: *Diag, obj: ObjectMap, key: []const u8, min_len: usize, max_len: usize) ValidationError![]const u8 {
    const v = obj.get(key) orelse {
        d.set("Field '{s}' is required", .{key});
        return error.Invalid;
    };
    return checkString(d, key, v, min_len, max_len);
}

fn optionalString(d: *Diag, obj: ObjectMap, key: []const u8, min_len: usize, max_len: usize) ValidationError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return try checkString(d, key, v, min_len, max_len);
}

fn checkString(d: *Diag, key: []const u8, v: Value, min_len: usize, max_len: usize) ValidationError![]const u8 {
    if (v != .string) {
        d.set("Field '{s}' must be a string", .{key});
        return error.Invalid;
    }
    const len = charCount(v.string);
    if (len < min_len or len > max_len) {
        d.set("Field '{s}' must be between {d} and {d} characters", .{ key, min_len, max_len });
        return error.Invalid;
    }
    return v.string;
}

/// Length in characters (Unicode code points), which is what the contract's
/// `minLength`/`maxLength` count — a 200-character name may be 800 bytes.
/// std.json only yields valid UTF-8, so the count cannot fail; a malformed
/// string is treated as too long rather than crashing.
fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch std.math.maxInt(usize);
}

/// Like `requireString`, but the value must be an ISO-8601 UTC timestamp
/// (`format: date-time` in the contract). Rejects e.g. `"x"` or `2026-02-30`.
fn requireDateTime(d: *Diag, obj: ObjectMap, key: []const u8) ValidationError![]const u8 {
    const v = obj.get(key) orelse {
        d.set("Field '{s}' is required", .{key});
        return error.Invalid;
    };
    return checkDateTime(d, key, v);
}

/// Optional `date-time` field: absent -> null, present -> must be valid.
fn optionalDateTime(d: *Diag, obj: ObjectMap, key: []const u8) ValidationError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return try checkDateTime(d, key, v);
}

fn checkDateTime(d: *Diag, key: []const u8, v: Value) ValidationError![]const u8 {
    if (v != .string or !time_util.isIso8601Utc(v.string)) {
        d.set("Field '{s}' must be an ISO 8601 UTC timestamp like 2026-06-19T14:30:00Z", .{key});
        return error.Invalid;
    }
    return v.string;
}

fn requireEnum(d: *Diag, obj: ObjectMap, key: []const u8, comptime allowed: []const []const u8) ValidationError![]const u8 {
    const v = obj.get(key) orelse {
        d.set("Field '{s}' is required", .{key});
        return error.Invalid;
    };
    return checkEnum(d, key, v, allowed);
}

fn optionalEnum(d: *Diag, obj: ObjectMap, key: []const u8, comptime allowed: []const []const u8) ValidationError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return try checkEnum(d, key, v, allowed);
}

fn checkEnum(d: *Diag, key: []const u8, v: Value, comptime allowed: []const []const u8) ValidationError![]const u8 {
    return matchEnum(v, allowed) orelse {
        d.set("Field '{s}' must be one of: {s}", .{ key, comptime joinComma(allowed) });
        return error.Invalid;
    };
}

/// "a, b, c" for an enum table, computed at compile time so the message needs
/// no allocation.
fn joinComma(comptime items: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else ", ") ++ item;
        return out;
    }
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

/// A minimal valid `PursuitCreate` body, reused by tests that only need *a*
/// valid pursuit (not specific field values).
const valid_pursuit =
    \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
;

/// Create a pursuit from `body_json` and return its id, duped into `a` so it
/// survives later mutations to the store tree. Collapses the
/// parse -> create -> dupe-id dance repeated across the mutation tests.
fn createPursuitId(s: *Store, a: Allocator, body_json: []const u8) ![]const u8 {
    const created = try s.create(try parse(a, body_json));
    return a.dupe(u8, created.object.get("id").?.string);
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
    const id = try createPursuitId(&s, a, valid_pursuit);
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

    const id = try createPursuitId(&s, a, valid_pursuit);

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

    const pid = try createPursuitId(&s, a, valid_pursuit);
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

    const pid = try createPursuitId(&s, a, valid_pursuit);
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

test "create rejects non-date-time target_date / started_at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    // Bad target_date.
    try testing.expectError(StoreError.Invalid, s.create(try parse(a,
        \\{"name":"X","type":"training","target_date":"x","started_at":"2026-06-01T00:00:00Z"}
    )));
    // Bad started_at.
    try testing.expectError(StoreError.Invalid, s.create(try parse(a,
        \\{"name":"X","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"nope"}
    )));
    // Well-formed but impossible calendar date.
    try testing.expectError(StoreError.Invalid, s.create(try parse(a,
        \\{"name":"X","type":"training","target_date":"2026-02-30T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    )));
}

test "createMilestone rejects non-date-time date" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const pid = try createPursuitId(&s, a, valid_pursuit);
    try testing.expectError(StoreError.Invalid, s.createMilestone(pid, try parse(a,
        \\{"name":"E","date":"someday"}
    )));
}

test "flush is atomic: data reloads and no .tmp file is left behind" {
    const io = testIo();
    const path = "/tmp/training-tracker-atomic-test.json";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var s = try Store.init(testing.allocator, io, path);
        defer s.deinit();
        _ = try s.create(try parse(a, valid_pursuit));
        try s.flush();
    }

    // A successful atomic flush leaves no temp file (it was renamed over `path`).
    // The temp name is `<path>.<pid>.tmp` (see `flush`).
    const tmp_path = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    const leftover = std.Io.Dir.cwd().readFileAlloc(io, tmp_path, a, std.Io.Limit.limited(1024));
    try testing.expectError(error.FileNotFound, leftover);

    // And the data round-trips on reload.
    var s2 = try Store.init(testing.allocator, io, path);
    defer s2.deinit();
    const res = try s2.list(a, null, 50, 0);
    try testing.expectEqual(@as(usize, 1), res.total);
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

test "validation failures leave a details message naming the field and rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const cases = [_]struct { body: []const u8, details: []const u8 }{
        .{ .body = "{\"type\":\"training\"}", .details = "Field 'name' is required" },
        .{ .body = "{\"name\":\"n\",\"type\":\"nope\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}", .details = "Field 'type' must be one of: certification, training" },
        .{ .body = "{\"name\":\"n\",\"type\":\"training\",\"target_date\":\"someday\",\"started_at\":\"2026-06-01T00:00:00Z\"}", .details = "Field 'target_date' must be an ISO 8601 UTC timestamp like 2026-06-19T14:30:00Z" },
        .{ .body = "{\"name\":\"\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\"}", .details = "Field 'name' must be between 1 and 200 characters" },
        .{ .body = "{\"name\":\"n\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\",\"tags\":\"cloud\"}", .details = "Field 'tags' must be an array of at most 20 strings" },
        .{ .body = "{\"name\":\"n\",\"type\":\"training\",\"target_date\":\"2026-12-31T00:00:00Z\",\"started_at\":\"2026-06-01T00:00:00Z\",\"milestones\":[{\"name\":\"m\"}]}", .details = "Field 'milestones[0].date' is required" },
        .{ .body = "[]", .details = "Request body must be a JSON object" },
    };
    for (cases) |case| {
        try testing.expectError(StoreError.Invalid, s.create(try parse(a, case.body)));
        try testing.expectEqualStrings(case.details, s.diag.message().?);
    }

    // A later valid mutation clears the stale message.
    _ = try s.create(try parse(a, valid_pursuit));
    try testing.expect(s.diag.message() == null);
}

test "updateMilestone reports a bad state with the allowed values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const pid = try createPursuitId(&s, a, valid_pursuit);
    const m = try s.createMilestone(pid, try parse(a, "{\"name\":\"E\",\"date\":\"2026-07-15T00:00:00Z\"}"));
    const mid = try a.dupe(u8, m.object.get("id").?.string);

    try testing.expectError(StoreError.Invalid, s.updateMilestone(pid, mid, try parse(a, "{\"state\":\"done\"}")));
    try testing.expectEqualStrings("Field 'state' must be one of: pending, achieved", s.diag.message().?);
}

test "string limits count characters, not bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    // 200 x U+00E9 (2 bytes each) is 400 bytes but exactly maxLength characters.
    const name200 = "é" ** 200;
    const ok = try std.fmt.allocPrint(a,
        \\{{"name":"{s}","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","tags":["{s}"]}}
    , .{ name200, "日" ** 50 });
    _ = try s.create(try parse(a, ok));

    const too_long = try std.fmt.allocPrint(a,
        \\{{"name":"{s}","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}}
    , .{"é" ** 201});
    try testing.expectError(StoreError.Invalid, s.create(try parse(a, too_long)));
    try testing.expectEqualStrings("Field 'name' must be between 1 and 200 characters", s.diag.message().?);
}

test "createMilestone answers Conflict once the pursuit holds the maximum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testStore(testing.allocator);
    defer s.deinit();

    const pid = try createPursuitId(&s, a, valid_pursuit);
    for (0..max_milestones) |_| {
        _ = try s.createMilestone(pid, try parse(a, "{\"name\":\"m\",\"date\":\"2026-07-15T00:00:00Z\"}"));
    }
    try testing.expectError(StoreError.Conflict, s.createMilestone(pid, try parse(a, "{\"name\":\"one too many\",\"date\":\"2026-07-15T00:00:00Z\"}")));
    try testing.expectEqualStrings("Pursuit already has the maximum of 50 milestones", s.diag.message().?);
    try testing.expectEqual(@as(usize, max_milestones), (try s.get(pid)).object.get("milestones").?.array.items.len);
}

// ---- derivedStatus (issue #28) --------------------------------------------

fn statusFixture(a: Allocator, status: []const u8, expires_at: ?[]const u8) !ObjectMap {
    var obj = ObjectMap{};
    try obj.put(a, "status", .{ .string = status });
    if (expires_at) |e| try obj.put(a, "expires_at", .{ .string = e });
    return obj;
}

test "derivedStatus: a completed pursuit past expires_at reads expired" {
    const a = testing.allocator;
    var obj = try statusFixture(a, "completed", "2026-01-01T00:00:00Z");
    defer obj.deinit(a);
    try testing.expectEqualStrings("expired", derivedStatus(obj, "2026-06-15T12:00:00Z"));
}

test "derivedStatus: a completed pursuit with expires_at ahead stays completed" {
    const a = testing.allocator;
    var obj = try statusFixture(a, "completed", "2029-12-15T00:00:00Z");
    defer obj.deinit(a);
    try testing.expectEqualStrings("completed", derivedStatus(obj, "2026-06-15T12:00:00Z"));
}

test "derivedStatus: the comparison is to the second, fractions ignored" {
    const a = testing.allocator;
    var same = try statusFixture(a, "completed", "2026-06-15T12:00:00.500Z");
    defer same.deinit(a);
    try testing.expectEqualStrings("completed", derivedStatus(same, "2026-06-15T12:00:00Z"));
    var earlier = try statusFixture(a, "completed", "2026-06-15T11:59:59.999Z");
    defer earlier.deinit(a);
    try testing.expectEqualStrings("expired", derivedStatus(earlier, "2026-06-15T12:00:00Z"));
}

test "derivedStatus: without expires_at the stored status stands" {
    const a = testing.allocator;
    var obj = try statusFixture(a, "completed", null);
    defer obj.deinit(a);
    try testing.expectEqualStrings("completed", derivedStatus(obj, "2026-06-15T12:00:00Z"));
}

test "derivedStatus: only a completed pursuit can expire" {
    const a = testing.allocator;
    var obj = try statusFixture(a, "in_progress", "2026-01-01T00:00:00Z");
    defer obj.deinit(a);
    try testing.expectEqualStrings("in_progress", derivedStatus(obj, "2026-06-15T12:00:00Z"));
}

test "derivedStatus: expired set by hand stays expired" {
    const a = testing.allocator;
    var obj = try statusFixture(a, "expired", "2029-12-15T00:00:00Z");
    defer obj.deinit(a);
    try testing.expectEqualStrings("expired", derivedStatus(obj, "2026-06-15T12:00:00Z"));
}

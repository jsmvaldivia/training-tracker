//! Acceptance tests for the derived `expired` status (issue #28).
//!
//! The rule lives in the API, on read: a `completed` pursuit whose
//! `expires_at` has passed is reported as `expired` by every operation that
//! returns a pursuit, while the store keeps the explicit `completed`. These
//! tests drive `pursuits.handle` directly (no sockets), the same style as
//! `acceptance_milestones.zig`, and check the stored value through the store.

const std = @import("std");
const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const json = std.json;
const Value = json.Value;
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

fn req(s: *Store, method: std.http.Method, target: []const u8, body: []const u8) !pursuits.Response {
    return (try pursuits.handle(testing.allocator, s, method, target, body)).?;
}

/// Sends the request, asserts the status code, and returns the `status`
/// field of the JSON body (the caller frees it).
fn statusOf(s: *Store, method: std.http.Method, target: []const u8, body: []const u8, expect: std.http.Status) ![]const u8 {
    const r = try req(s, method, target, body);
    defer testing.allocator.free(r.body);
    try testing.expectEqual(expect, r.status);
    const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    return testing.allocator.dupe(u8, parsed.value.object.get("status").?.string);
}

fn idOf(s: *Store, body: []const u8) ![]const u8 {
    const r = try req(s, .POST, "/pursuits", body);
    defer testing.allocator.free(r.body);
    try testing.expectEqual(std.http.Status.created, r.status);
    const parsed = try json.parseFromSlice(Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    return testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
}

const past_cert =
    \\{"name":"Old cert","type":"certification","status":"completed","target_date":"2019-12-31T00:00:00Z","started_at":"2019-06-01T00:00:00Z","expires_at":"2020-01-01T00:00:00Z"}
;
const future_cert =
    \\{"name":"Fresh cert","type":"certification","status":"completed","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","expires_at":"2999-01-01T00:00:00Z"}
;

test "acceptance: a completed pursuit past expires_at reads expired on create, get, and list" {
    const path = "/tmp/tt-acc-expiry-read.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const created = try statusOf(&s, .POST, "/pursuits", past_cert, .created);
    defer testing.allocator.free(created);
    try testing.expectEqualStrings("expired", created);

    const list = try req(&s, .GET, "/pursuits", "");
    defer testing.allocator.free(list.body);
    const parsed = try json.parseFromSlice(Value, testing.allocator, list.body, .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("data").?.array.items[0].object;
    try testing.expectEqualStrings("expired", first.get("status").?.string);

    const id = try testing.allocator.dupe(u8, first.get("id").?.string);
    defer testing.allocator.free(id);
    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);
    const got = try statusOf(&s, .GET, target, "", .ok);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("expired", got);
}

test "acceptance: the derived status is never stored" {
    const path = "/tmp/tt-acc-expiry-stored.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const id = try idOf(&s, past_cert);
    defer testing.allocator.free(id);

    // Reading it does not change what the store holds ...
    const stored = try s.get(id);
    try testing.expectEqualStrings("completed", stored.object.get("status").?.string);

    // ... nor what the file holds: a fresh store reads the file back.
    var reloaded = try Store.init(testing.allocator, testIo(), path);
    defer reloaded.deinit();
    const on_disk = try reloaded.get(id);
    try testing.expectEqualStrings("completed", on_disk.object.get("status").?.string);
}

test "acceptance: a completed pursuit with expires_at ahead reads completed" {
    const path = "/tmp/tt-acc-expiry-future.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const created = try statusOf(&s, .POST, "/pursuits", future_cert, .created);
    defer testing.allocator.free(created);
    try testing.expectEqualStrings("completed", created);
}

test "acceptance: PATCH to completed on a pursuit past expires_at answers expired" {
    const path = "/tmp/tt-acc-expiry-patch-status.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const id = try idOf(&s,
        \\{"name":"Old cert","type":"certification","status":"in_progress","target_date":"2019-12-31T00:00:00Z","started_at":"2019-06-01T00:00:00Z","expires_at":"2020-01-01T00:00:00Z"}
    );
    defer testing.allocator.free(id);
    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);

    // Not obtained yet: a past expires_at does not expire it.
    const before = try statusOf(&s, .GET, target, "", .ok);
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("in_progress", before);

    const after = try statusOf(&s, .PATCH, target, "{\"status\":\"completed\"}", .ok);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("expired", after);
}

test "acceptance: PATCH expires_at into the past on a completed pursuit answers expired" {
    const path = "/tmp/tt-acc-expiry-patch-date.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const id = try idOf(&s, future_cert);
    defer testing.allocator.free(id);
    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(target);

    const after = try statusOf(&s, .PATCH, target, "{\"expires_at\":\"2020-01-01T00:00:00Z\"}", .ok);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("expired", after);
}

test "acceptance: expired set by hand is reported as sent" {
    const path = "/tmp/tt-acc-expiry-manual.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const created = try statusOf(&s, .POST, "/pursuits",
        \\{"name":"Retired","type":"certification","status":"expired","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","expires_at":"2999-01-01T00:00:00Z"}
    , .created);
    defer testing.allocator.free(created);
    try testing.expectEqualStrings("expired", created);
}

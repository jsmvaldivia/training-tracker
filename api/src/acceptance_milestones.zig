//! Acceptance tests for milestone endpoints.
//!
//! These exercise the routing + handler + store path by invoking
//! `pursuits.handle` directly (no sockets), then verify persistence side
//! effects — the same style as the acceptance tests in `pursuits.zig`. Socket
//! plumbing for milestones is covered by the integration tests in
//! `http_test_update.zig`. Each test creates a fresh store and pursuit, then
//! exercises one milestone endpoint.

const std = @import("std");
const pursuits = @import("pursuits.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const json = std.json;
const Value = json.Value;
const testing = std.testing;

// Test infrastructure.
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
) !pursuits.Response {
    const r = (try pursuits.handle(testing.allocator, s, method, target, body)).?;
    return r;
}

/// Helper to create a pursuit and return its ID.
fn createPursuit(s: *Store) ![]const u8 {
    const create = try req(s, .POST, "/pursuits",
        \\{"name":"Test Pursuit","type":"training","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}
    );
    defer testing.allocator.free(create.body);

    const parsed = try json.parseFromSlice(Value, testing.allocator, create.body, .{});
    defer parsed.deinit();
    return testing.allocator.dupe(u8, parsed.value.object.get("id").?.string);
}

// ---- Tests ----------------------------------------------------------------

test "POST /pursuits/{id}/milestones with valid body returns 201" {
    const path = "/tmp/tt-http-ms-create.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(target);

    const body =
        \\{"name":"Complete module 1","date":"2026-07-15T00:00:00Z"}
    ;

    const resp = try req(&s, .POST, target, body);
    defer testing.allocator.free(resp.body);

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();

    const m = parsed.value.object;
    try testing.expect(m.get("id") != null);
    try testing.expectEqualStrings("Complete module 1", m.get("name").?.string);
    try testing.expectEqualStrings("pending", m.get("state").?.string);
}

test "POST /pursuits/{id}/milestones on non-existent pursuit returns 404" {
    const path = "/tmp/tt-http-ms-404.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const body =
        \\{"name":"Test","date":"2026-07-15T00:00:00Z"}
    ;

    const resp = try req(&s, .POST, "/pursuits/nonexistent/milestones", body);
    defer testing.allocator.free(resp.body);

    try testing.expectEqual(std.http.Status.not_found, resp.status);
}

test "POST /pursuits/{id}/milestones with state=achieved auto-sets achieved_at" {
    const path = "/tmp/tt-http-ms-achieved.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(target);

    const body =
        \\{"name":"Already done","date":"2026-07-15T00:00:00Z","state":"achieved"}
    ;

    const resp = try req(&s, .POST, target, body);
    defer testing.allocator.free(resp.body);

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try json.parseFromSlice(Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();

    const m = parsed.value.object;
    try testing.expectEqualStrings("achieved", m.get("state").?.string);
    try testing.expect(m.get("achieved_at") != null);
}

test "PATCH /pursuits/{id}/milestones/{mid} toggle state pending->achieved sets achieved_at" {
    const path = "/tmp/tt-http-ms-toggle-achieved.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    // Create milestone with state=pending.
    const create_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(create_target);

    const create_body =
        \\{"name":"Study","date":"2026-07-15T00:00:00Z"}
    ;

    const create_resp = try req(&s, .POST, create_target, create_body);
    defer testing.allocator.free(create_resp.body);

    const create_parsed = try json.parseFromSlice(Value, testing.allocator, create_resp.body, .{});
    defer create_parsed.deinit();
    const mid = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(mid);

    // Now PATCH to toggle state to achieved.
    const patch_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(patch_target);

    const patch_body =
        \\{"state":"achieved"}
    ;

    const patch_resp = try req(&s, .PATCH, patch_target, patch_body);
    defer testing.allocator.free(patch_resp.body);

    try testing.expectEqual(std.http.Status.ok, patch_resp.status);

    const patch_parsed = try json.parseFromSlice(Value, testing.allocator, patch_resp.body, .{});
    defer patch_parsed.deinit();

    const m = patch_parsed.value.object;
    try testing.expectEqualStrings("achieved", m.get("state").?.string);
    try testing.expect(m.get("achieved_at") != null);
}

test "PATCH /pursuits/{id}/milestones/{mid} toggle state achieved->pending clears achieved_at" {
    const path = "/tmp/tt-http-ms-toggle-pending.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    // Create milestone with state=achieved.
    const create_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(create_target);

    const create_body =
        \\{"name":"Done","date":"2026-07-15T00:00:00Z","state":"achieved"}
    ;

    const create_resp = try req(&s, .POST, create_target, create_body);
    defer testing.allocator.free(create_resp.body);

    const create_parsed = try json.parseFromSlice(Value, testing.allocator, create_resp.body, .{});
    defer create_parsed.deinit();
    const mid = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(mid);

    // Verify it has achieved_at.
    try testing.expect(create_parsed.value.object.get("achieved_at") != null);

    // Now PATCH to toggle state to pending.
    const patch_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(patch_target);

    const patch_body =
        \\{"state":"pending"}
    ;

    const patch_resp = try req(&s, .PATCH, patch_target, patch_body);
    defer testing.allocator.free(patch_resp.body);

    try testing.expectEqual(std.http.Status.ok, patch_resp.status);

    const patch_parsed = try json.parseFromSlice(Value, testing.allocator, patch_resp.body, .{});
    defer patch_parsed.deinit();

    const m = patch_parsed.value.object;
    try testing.expectEqualStrings("pending", m.get("state").?.string);
    try testing.expect(m.get("achieved_at") == null);
}

test "PATCH /pursuits/{id}/milestones/{mid} update name and date" {
    const path = "/tmp/tt-http-ms-update.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    // Create milestone.
    const create_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(create_target);

    const create_body =
        \\{"name":"Original","date":"2026-07-15T00:00:00Z"}
    ;

    const create_resp = try req(&s, .POST, create_target, create_body);
    defer testing.allocator.free(create_resp.body);

    const create_parsed = try json.parseFromSlice(Value, testing.allocator, create_resp.body, .{});
    defer create_parsed.deinit();
    const mid = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(mid);

    // Update name and date.
    const patch_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(patch_target);

    const patch_body =
        \\{"name":"Updated Name","date":"2026-08-01T00:00:00Z"}
    ;

    const patch_resp = try req(&s, .PATCH, patch_target, patch_body);
    defer testing.allocator.free(patch_resp.body);

    try testing.expectEqual(std.http.Status.ok, patch_resp.status);

    const patch_parsed = try json.parseFromSlice(Value, testing.allocator, patch_resp.body, .{});
    defer patch_parsed.deinit();

    const m = patch_parsed.value.object;
    try testing.expectEqualStrings("Updated Name", m.get("name").?.string);
    try testing.expectEqualStrings("2026-08-01T00:00:00Z", m.get("date").?.string);
}

test "PATCH /pursuits/{id}/milestones/{mid} with unknown pursuit id returns 404" {
    const path = "/tmp/tt-http-ms-unknown-pursuit.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const body =
        \\{"state":"achieved"}
    ;

    const resp = try req(&s, .PATCH, "/pursuits/nonexistent/milestones/m_1", body);
    defer testing.allocator.free(resp.body);

    try testing.expectEqual(std.http.Status.not_found, resp.status);
}

test "PATCH /pursuits/{id}/milestones/{mid} with unknown milestone id returns 404" {
    const path = "/tmp/tt-http-ms-unknown-milestone.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    const target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/nonexistent", .{pid});
    defer testing.allocator.free(target);

    const body =
        \\{"state":"achieved"}
    ;

    const resp = try req(&s, .PATCH, target, body);
    defer testing.allocator.free(resp.body);

    try testing.expectEqual(std.http.Status.not_found, resp.status);
}

test "DELETE /pursuits/{id}/milestones/{mid} returns 204" {
    const path = "/tmp/tt-http-ms-delete.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    // Create milestone.
    const create_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(create_target);

    const create_body =
        \\{"name":"To Delete","date":"2026-07-15T00:00:00Z"}
    ;

    const create_resp = try req(&s, .POST, create_target, create_body);
    defer testing.allocator.free(create_resp.body);

    const create_parsed = try json.parseFromSlice(Value, testing.allocator, create_resp.body, .{});
    defer create_parsed.deinit();
    const mid = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(mid);

    // Delete milestone.
    const delete_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(delete_target);

    const delete_resp = try req(&s, .DELETE, delete_target, "");

    try testing.expectEqual(std.http.Status.no_content, delete_resp.status);
    try testing.expectEqual(@as(usize, 0), delete_resp.body.len);
}

test "DELETE /pursuits/{id}/milestones/{mid} verify milestone is gone" {
    const path = "/tmp/tt-http-ms-delete-verify.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    // Create milestone.
    const create_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones", .{pid});
    defer testing.allocator.free(create_target);

    const create_body =
        \\{"name":"To Delete","date":"2026-07-15T00:00:00Z"}
    ;

    const create_resp = try req(&s, .POST, create_target, create_body);
    defer testing.allocator.free(create_resp.body);

    const create_parsed = try json.parseFromSlice(Value, testing.allocator, create_resp.body, .{});
    defer create_parsed.deinit();
    const mid = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(mid);

    // Delete milestone.
    const delete_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/{s}", .{ pid, mid });
    defer testing.allocator.free(delete_target);

    _ = try req(&s, .DELETE, delete_target, "");

    // Verify by fetching the pursuit and checking milestones array.
    const get_target = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{pid});
    defer testing.allocator.free(get_target);

    const get_resp = try req(&s, .GET, get_target, "");
    defer testing.allocator.free(get_resp.body);

    const get_parsed = try json.parseFromSlice(Value, testing.allocator, get_resp.body, .{});
    defer get_parsed.deinit();

    const milestones = get_parsed.value.object.get("milestones").?.array;
    try testing.expectEqual(@as(usize, 0), milestones.items.len);
}

test "DELETE /pursuits/{id}/milestones/{mid} with unknown ids returns 404" {
    const path = "/tmp/tt-http-ms-delete-404.json";
    var s = try freshStore(path);
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteFile(testIo(), path) catch {};

    // Test with unknown pursuit ID.
    const resp1 = try req(&s, .DELETE, "/pursuits/nonexistent/milestones/m_1", "");
    defer testing.allocator.free(resp1.body);
    try testing.expectEqual(std.http.Status.not_found, resp1.status);

    // Test with valid pursuit but unknown milestone.
    const pid = try createPursuit(&s);
    defer testing.allocator.free(pid);

    const target2 = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}/milestones/nonexistent", .{pid});
    defer testing.allocator.free(target2);

    const resp2 = try req(&s, .DELETE, target2, "");
    defer testing.allocator.free(resp2.body);
    try testing.expectEqual(std.http.Status.not_found, resp2.status);
}

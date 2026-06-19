//! HTTP integration tests for PATCH /pursuits/{id} and DELETE /pursuits/{id}.
//!
//! Real HTTP tests using std.http.Client against a live server instance.
//! Each test spawns its own server with a unique data.json to ensure isolation.
//! Tests verify both HTTP responses and persistence side effects.

const std = @import("std");
const http_test = @import("http_test.zig");
const testing = std.testing;
const json = std.json;
const Value = json.Value;

/// Helper to create a pursuit and return its ID.
fn createPursuit(port: u16, name: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(testing.allocator,
        \\{{"name":"{s}","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}}
    , .{name});
    defer testing.allocator.free(body);

    var resp = try http_test.post(testing.allocator, port, "/pursuits", body);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.created, resp.status);

    const parsed = try http_test.parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    return http_test.extractId(testing.allocator, parsed.value);
}

// ============================================================================
// PATCH /pursuits/{id} tests
// ============================================================================

test "http: PATCH /pursuits/{id} with partial update (name only) returns 200" {
    const port: u16 = 8100;
    const data_path = "/tmp/tt-http-patch-partial.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    const id = try createPursuit(port, "Original Name");
    defer testing.allocator.free(id);

    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    var resp = try http_test.patch(testing.allocator, port, path, "{\"name\":\"Updated Name\"}");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.ok, resp.status);

    const parsed = try http_test.parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try testing.expectEqualStrings("Updated Name", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings(id, parsed.value.object.get("id").?.string);
}

test "http: PATCH /pursuits/{id} updating status to completed auto-sets completed_at" {
    const port: u16 = 8101;
    const data_path = "/tmp/tt-http-patch-completed.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    const id = try createPursuit(port, "Test Pursuit");
    defer testing.allocator.free(id);

    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    var resp = try http_test.patch(testing.allocator, port, path, "{\"status\":\"completed\"}");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.ok, resp.status);

    const parsed = try http_test.parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try testing.expectEqualStrings("completed", parsed.value.object.get("status").?.string);
    try testing.expect(parsed.value.object.get("completed_at") != null);
    try testing.expect(parsed.value.object.get("completed_at").? == .string);
}

test "http: PATCH /pursuits/{id} with invalid data returns 400" {
    const port: u16 = 8102;
    const data_path = "/tmp/tt-http-patch-invalid.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    const id = try createPursuit(port, "Test Pursuit");
    defer testing.allocator.free(id);

    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    // Invalid JSON syntax.
    var resp1 = try http_test.patch(testing.allocator, port, path, "{\"name\":}");
    defer resp1.deinit();
    try testing.expectEqual(std.http.Status.bad_request, resp1.status);

    // Empty name (violates minLength: 1).
    var resp2 = try http_test.patch(testing.allocator, port, path, "{\"name\":\"\"}");
    defer resp2.deinit();
    try testing.expectEqual(std.http.Status.bad_request, resp2.status);
}

test "http: PATCH /pursuits/{id} with unknown id returns 404" {
    const port: u16 = 8103;
    const data_path = "/tmp/tt-http-patch-404.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    var resp = try http_test.patch(testing.allocator, port, "/pursuits/nonexistent_id", "{\"name\":\"New Name\"}");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.not_found, resp.status);

    const parsed = try http_test.parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 404), parsed.value.object.get("status").?.integer);
}

test "http: PATCH /pursuits/{id} verify fields not sent remain unchanged" {
    const port: u16 = 8104;
    const data_path = "/tmp/tt-http-patch-unchanged.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create pursuit with all fields.
    const create_body =
        \\{"name":"Original","type":"certification","status":"in_progress","description":"Original description","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","tags":["tag1","tag2"]}
    ;
    var create_resp = try http_test.post(testing.allocator, port, "/pursuits", create_body);
    defer create_resp.deinit();

    const create_parsed = try http_test.parseJson(testing.allocator, create_resp.body);
    defer create_parsed.deinit();

    const id = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(id);

    const original_type = create_parsed.value.object.get("type").?.string;
    const original_status = create_parsed.value.object.get("status").?.string;
    const original_description = create_parsed.value.object.get("description").?.string;
    const original_target_date = create_parsed.value.object.get("target_date").?.string;

    // Update only the name.
    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    var update_resp = try http_test.patch(testing.allocator, port, path, "{\"name\":\"Updated\"}");
    defer update_resp.deinit();

    const update_parsed = try http_test.parseJson(testing.allocator, update_resp.body);
    defer update_parsed.deinit();

    // Name should be updated.
    try testing.expectEqualStrings("Updated", update_parsed.value.object.get("name").?.string);

    // Other fields should remain unchanged.
    try testing.expectEqualStrings(original_type, update_parsed.value.object.get("type").?.string);
    try testing.expectEqualStrings(original_status, update_parsed.value.object.get("status").?.string);
    try testing.expectEqualStrings(original_description, update_parsed.value.object.get("description").?.string);
    try testing.expectEqualStrings(original_target_date, update_parsed.value.object.get("target_date").?.string);
    try testing.expectEqual(@as(usize, 2), update_parsed.value.object.get("tags").?.array.items.len);
}

// ============================================================================
// DELETE /pursuits/{id} tests
// ============================================================================

test "http: DELETE /pursuits/{id} returns 204" {
    const port: u16 = 8105;
    const data_path = "/tmp/tt-http-delete-204.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    const id = try createPursuit(port, "To Delete");
    defer testing.allocator.free(id);

    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    var resp = try http_test.delete(testing.allocator, port, path);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.no_content, resp.status);
    try testing.expectEqual(@as(usize, 0), resp.body.len);
}

test "http: DELETE /pursuits/{id} verify pursuit is gone (subsequent GET returns 404)" {
    const port: u16 = 8106;
    const data_path = "/tmp/tt-http-delete-verify.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    const id = try createPursuit(port, "To Delete");
    defer testing.allocator.free(id);

    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    // Verify pursuit exists before deletion.
    var get_before = try http_test.get(testing.allocator, port, path);
    defer get_before.deinit();
    try testing.expectEqual(std.http.Status.ok, get_before.status);

    // Delete the pursuit.
    var delete_resp = try http_test.delete(testing.allocator, port, path);
    defer delete_resp.deinit();
    try testing.expectEqual(std.http.Status.no_content, delete_resp.status);

    // Verify pursuit is gone.
    var get_after = try http_test.get(testing.allocator, port, path);
    defer get_after.deinit();
    try testing.expectEqual(std.http.Status.not_found, get_after.status);
}

test "http: DELETE /pursuits/{id} with unknown id returns 404" {
    const port: u16 = 8107;
    const data_path = "/tmp/tt-http-delete-404.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    var resp = try http_test.delete(testing.allocator, port, "/pursuits/nonexistent_id");
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.not_found, resp.status);

    const parsed = try http_test.parseJson(testing.allocator, resp.body);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 404), parsed.value.object.get("status").?.integer);
}

test "http: DELETE /pursuits/{id} verify milestones are deleted too" {
    const port: u16 = 8108;
    const data_path = "/tmp/tt-http-delete-milestones.json";

    var server = try http_test.TestServer.start(testing.allocator, port, data_path);
    defer server.shutdown();

    // Create pursuit with milestones.
    const create_body =
        \\{"name":"With Milestones","type":"certification","target_date":"2026-12-31T00:00:00Z","started_at":"2026-06-01T00:00:00Z","milestones":[{"name":"Milestone 1","date":"2026-07-15T00:00:00Z"},{"name":"Milestone 2","date":"2026-08-15T00:00:00Z"}]}
    ;
    var create_resp = try http_test.post(testing.allocator, port, "/pursuits", create_body);
    defer create_resp.deinit();

    const create_parsed = try http_test.parseJson(testing.allocator, create_resp.body);
    defer create_parsed.deinit();

    const id = try testing.allocator.dupe(u8, create_parsed.value.object.get("id").?.string);
    defer testing.allocator.free(id);

    // Verify milestones exist.
    try testing.expectEqual(@as(usize, 2), create_parsed.value.object.get("milestones").?.array.items.len);

    // Delete the pursuit.
    const path = try std.fmt.allocPrint(testing.allocator, "/pursuits/{s}", .{id});
    defer testing.allocator.free(path);

    var delete_resp = try http_test.delete(testing.allocator, port, path);
    defer delete_resp.deinit();
    try testing.expectEqual(std.http.Status.no_content, delete_resp.status);

    // Verify pursuit is gone (which implicitly verifies milestones are gone too).
    var get_after = try http_test.get(testing.allocator, port, path);
    defer get_after.deinit();
    try testing.expectEqual(std.http.Status.not_found, get_after.status);
}

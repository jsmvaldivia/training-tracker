//! Small ISO 8601 (UTC) timestamp helper. The server stamps `completed_at`
//! and `achieved_at` with the current time when lifecycle transitions occur.

const std = @import("std");

/// Formats a Unix timestamp (seconds) as an ISO 8601 UTC string like
/// `2026-06-19T14:30:00Z` into `buf`. Returns the written slice.
pub fn formatIso8601(buf: []u8, unix_secs: u64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = unix_secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Current time as an ISO 8601 UTC string written into `buf`. Time is sourced
/// from the injected `Io` (the real/wall-clock).
pub fn nowIso8601(io: std.Io, buf: []u8) []const u8 {
    const secs = std.Io.Timestamp.now(io, .real).toSeconds();
    const u: u64 = if (secs < 0) 0 else @intCast(secs);
    return formatIso8601(buf, u);
}

/// Structurally validates an ISO 8601 UTC timestamp of the exact form
/// `YYYY-MM-DDThh:mm:ssZ` (20 chars) — the same shape `formatIso8601` emits, so
/// server-stamped values always pass. The OpenAPI contract declares this
/// `format: date-time` for `target_date`, `started_at`, `expires_at`, and
/// milestone `date`; the store enforces it on those client-supplied fields.
pub fn isIso8601(s: []const u8) bool {
    if (s.len != 20) return false;
    // Positions of the literal separators.
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or
        s[13] != ':' or s[16] != ':' or s[19] != 'Z') return false;

    const digit_positions = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (digit_positions) |i| {
        if (s[i] < '0' or s[i] > '9') return false;
    }

    const month = twoDigits(s, 5);
    const day = twoDigits(s, 8);
    const hour = twoDigits(s, 11);
    const minute = twoDigits(s, 14);
    const second = twoDigits(s, 17);

    if (month < 1 or month > 12) return false;
    if (day < 1 or day > 31) return false;
    if (hour > 23) return false;
    if (minute > 59) return false;
    if (second > 59) return false;
    return true;
}

fn twoDigits(s: []const u8, at: usize) u32 {
    return @as(u32, s[at] - '0') * 10 + @as(u32, s[at + 1] - '0');
}

test "formatIso8601 renders a known timestamp" {
    var buf: [32]u8 = undefined;
    // 2009-02-13T23:31:30Z
    const out = formatIso8601(&buf, 1_234_567_890);
    try std.testing.expectEqualStrings("2009-02-13T23:31:30Z", out);
}

test "isIso8601 accepts the form formatIso8601 emits" {
    var buf: [32]u8 = undefined;
    const out = formatIso8601(&buf, 1_234_567_890);
    try std.testing.expect(isIso8601(out));
    try std.testing.expect(isIso8601("2026-12-31T00:00:00Z"));
}

test "isIso8601 rejects malformed timestamps" {
    try std.testing.expect(!isIso8601("x"));
    try std.testing.expect(!isIso8601("")); // empty
    try std.testing.expect(!isIso8601("2026-12-31T00:00:00")); // missing Z
    try std.testing.expect(!isIso8601("2026-12-31 00:00:00Z")); // space instead of T
    try std.testing.expect(!isIso8601("2026/12/31T00:00:00Z")); // wrong separators
    try std.testing.expect(!isIso8601("2026-13-31T00:00:00Z")); // month 13
    try std.testing.expect(!isIso8601("2026-12-00T00:00:00Z")); // day 0
    try std.testing.expect(!isIso8601("2026-12-31T24:00:00Z")); // hour 24
    try std.testing.expect(!isIso8601("2026-12-31T00:60:00Z")); // minute 60
    try std.testing.expect(!isIso8601("2026-12-31T00:00:60Z")); // second 60
    try std.testing.expect(!isIso8601("202X-12-31T00:00:00Z")); // non-digit
}

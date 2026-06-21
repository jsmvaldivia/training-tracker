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

/// Validates an ISO 8601 / RFC 3339 UTC timestamp: `YYYY-MM-DDThh:mm:ss[.fff]Z`.
/// Only the `Z` (UTC) zone is accepted, with optional fractional seconds — this
/// matches both what `formatIso8601` emits and what JS `Date.toISOString()`
/// sends from the frontend. Day-of-month is range-checked against the month
/// (leap years included), so `2026-02-30T00:00:00Z` is rejected.
///
/// This is the validation the OpenAPI `format: date-time` fields require; the
/// store applies it to `target_date`, `started_at`, and milestone `date`.
pub fn isIso8601Utc(s: []const u8) bool {
    // Minimum: "YYYY-MM-DDThh:mm:ssZ" = 20 chars.
    if (s.len < 20) return false;

    if (!isDigits(s[0..4])) return false;
    if (s[4] != '-') return false;
    if (!isDigits(s[5..7])) return false;
    if (s[7] != '-') return false;
    if (!isDigits(s[8..10])) return false;
    if (s[10] != 'T') return false;
    if (!isDigits(s[11..13])) return false;
    if (s[13] != ':') return false;
    if (!isDigits(s[14..16])) return false;
    if (s[16] != ':') return false;
    if (!isDigits(s[17..19])) return false;

    const year = parse2(s[0..4]);
    const month = parse2(s[5..7]);
    const day = parse2(s[8..10]);
    const hour = parse2(s[11..13]);
    const minute = parse2(s[14..16]);
    const second = parse2(s[17..19]);

    if (month < 1 or month > 12) return false;
    if (day < 1 or day > daysInMonth(year, month)) return false;
    if (hour > 23) return false;
    if (minute > 59) return false;
    if (second > 59) return false;

    // Optional fractional seconds: ".<digits>" before the zone.
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == frac_start) return false; // "." with no digits
    }

    // Zone must be exactly "Z" and the final character.
    return i == s.len - 1 and s[i] == 'Z';
}

fn isDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn parse2(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| n = n * 10 + (c - '0');
    return n;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else 28,
        else => 0,
    };
}

test "formatIso8601 renders a known timestamp" {
    var buf: [32]u8 = undefined;
    // 2009-02-13T23:31:30Z
    const out = formatIso8601(&buf, 1_234_567_890);
    try std.testing.expectEqualStrings("2009-02-13T23:31:30Z", out);
}

test "isIso8601Utc accepts valid UTC timestamps" {
    try std.testing.expect(isIso8601Utc("2026-12-31T23:59:59Z"));
    try std.testing.expect(isIso8601Utc("2026-06-01T00:00:00Z"));
    // Fractional seconds (as JS Date.toISOString() emits).
    try std.testing.expect(isIso8601Utc("2026-06-01T00:00:00.000Z"));
    try std.testing.expect(isIso8601Utc("2028-02-29T12:00:00Z")); // valid leap day
}

test "isIso8601Utc rejects malformed or out-of-range timestamps" {
    try std.testing.expect(!isIso8601Utc("x"));
    try std.testing.expect(!isIso8601Utc(""));
    try std.testing.expect(!isIso8601Utc("2026-12-31T23:59:59")); // missing Z
    try std.testing.expect(!isIso8601Utc("2026-12-31 23:59:59Z")); // space, not T
    try std.testing.expect(!isIso8601Utc("2026-13-01T00:00:00Z")); // month 13
    try std.testing.expect(!isIso8601Utc("2026-02-30T00:00:00Z")); // Feb 30
    try std.testing.expect(!isIso8601Utc("2025-02-29T00:00:00Z")); // not a leap year
    try std.testing.expect(!isIso8601Utc("2026-12-31T24:00:00Z")); // hour 24
    try std.testing.expect(!isIso8601Utc("2026-12-31T23:59:59.Z")); // dot, no digits
    try std.testing.expect(!isIso8601Utc("2026-12-31T23:59:59+00:00")); // offset zone
}

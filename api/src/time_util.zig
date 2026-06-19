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

test "formatIso8601 renders a known timestamp" {
    var buf: [32]u8 = undefined;
    // 2009-02-13T23:31:30Z
    const out = formatIso8601(&buf, 1_234_567_890);
    try std.testing.expectEqualStrings("2009-02-13T23:31:30Z", out);
}

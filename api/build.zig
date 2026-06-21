const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "training-tracker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run` — start the HTTP server.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the HTTP server");
    run_step.dependOn(&run_cmd.step);

    // Optional `-Dtest-filter=...` to run a subset of tests by name.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    // Test steps, split by cost so the tight dev loop stays fast:
    //   test:unit — pure unit + acceptance tests, no sockets (milliseconds)
    //   test:http — HTTP integration tests, real server on a background thread
    //   test      — the full gate (depends on both)
    const unit_step = b.step("test:unit", "Fast unit + acceptance tests (no sockets)");
    const http_step = b.step("test:http", "HTTP integration tests (real server + sockets)");
    const test_step = b.step("test", "All tests — the pre-commit gate");
    test_step.dependOn(unit_step);
    test_step.dependOn(http_step);

    // Fast, socket-free tests: domain logic, time helpers, handler acceptance.
    // Each file is its own test binary (see `addTests`); main.zig is included
    // here too rather than as a separate `exe.root_module` test, so every test
    // runs in exactly one process. Running a file's tests in two binaries at
    // once would race on the hardcoded /tmp data paths the tests share.
    const unit_files = [_][]const u8{
        "src/main.zig",
        "src/time_util.zig",
        "src/store.zig",
        "src/pursuits.zig",
        "src/acceptance_milestones.zig",
    };
    // Integration tests: spin up a real HTTP server and talk to it over sockets.
    const http_files = [_][]const u8{
        "src/http_test.zig",
        "src/http_test_create.zig",
        "src/http_test_update.zig",
    };

    addTests(b, target, optimize, filters, unit_step, &unit_files);
    addTests(b, target, optimize, filters, http_step, &http_files);
}

/// Add a per-file test artifact to `step` for each path in `files`. Separate
/// artifacts ensure each file's tests run regardless of whether `main`
/// references every declaration.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filters: []const []const u8,
    step: *std.Build.Step,
    files: []const []const u8,
) void {
    for (files) |tf| {
        const mod_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = target,
                .optimize = optimize,
            }),
            .filters = filters,
        });
        step.dependOn(&b.addRunArtifact(mod_tests).step);
    }
}

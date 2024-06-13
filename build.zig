const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("curl", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const ext_deps: []const []const u8 = if (builtin.os.tag == .windows)
        &.{
            "curl",      "bcrypt",    "crypto",       "crypt32", "ws2_32",
            "wldap32",   "ssl",       "psl",          "iconv",   "idn2",
            "unistring", "z",         "zstd",         "nghttp2", "ssh2",
            "brotlienc", "brotlidec", "brotlicommon",
        }
    else
        &.{"libcurl"};

    const lib = b.addStaticLibrary(.{
        .name = "zig-curl",
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

    lib.linkLibC();
    inline for (ext_deps) |dep| lib.linkSystemLibrary(dep);

    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    const run_tests_step = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests_step.step);
}

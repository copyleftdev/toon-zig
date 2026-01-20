const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const toon_module = b.addModule("toon", .{
        .root_source_file = b.path("src/toon.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library artifact for linking
    const lib = b.addStaticLibrary(.{
        .name = "toon",
        .root_source_file = b.path("src/toon.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/toon.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Fixture tests (run against reference test suite)
    const fixture_tests = b.addTest(.{
        .root_source_file = b.path("tests/fixture_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_tests.root_module.addImport("toon", toon_module);

    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    // Round-trip tests
    const roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("tests/roundtrip_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    roundtrip_tests.root_module.addImport("toon", toon_module);

    const run_roundtrip_tests = b.addRunArtifact(roundtrip_tests);

    // Chaos tests (property-based)
    const chaos_tests = b.addTest(.{
        .root_source_file = b.path("tests/chaos_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    chaos_tests.root_module.addImport("toon", toon_module);

    const run_chaos_tests = b.addRunArtifact(chaos_tests);

    // Fuzz tests (Zig native fuzzer)
    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("tests/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_tests.root_module.addImport("toon", toon_module);

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Fixture test step
    const fixture_test_step = b.step("test-fixtures", "Run reference fixture tests");
    fixture_test_step.dependOn(&run_fixture_tests.step);

    // Round-trip test step
    const roundtrip_test_step = b.step("test-roundtrip", "Run round-trip tests");
    roundtrip_test_step.dependOn(&run_roundtrip_tests.step);

    // Chaos test step (property-based)
    const chaos_test_step = b.step("test-chaos", "Run property-based chaos tests");
    chaos_test_step.dependOn(&run_chaos_tests.step);

    // Fuzz test step (quick tests, use --fuzz for actual fuzzing)
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz test edge cases");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    // All tests (fast)
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_lib_unit_tests.step);
    all_tests_step.dependOn(&run_fixture_tests.step);
    all_tests_step.dependOn(&run_roundtrip_tests.step);
    all_tests_step.dependOn(&run_fuzz_tests.step);

    // Full tests including chaos
    const full_tests_step = b.step("test-full", "Run all tests including chaos");
    full_tests_step.dependOn(&run_lib_unit_tests.step);
    full_tests_step.dependOn(&run_fixture_tests.step);
    full_tests_step.dependOn(&run_roundtrip_tests.step);
    full_tests_step.dependOn(&run_fuzz_tests.step);
    full_tests_step.dependOn(&run_chaos_tests.step);
}

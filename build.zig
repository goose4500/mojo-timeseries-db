const std = @import("std");

const mojo_sources = [_][]const u8{
    "src/aggregations.mojo", "src/engine.mojo",            "src/storage.mojo",                 "src/tsdb.mojo",
    "tests/tests.mojo",      "benchmarks/benchmarks.mojo", "examples/custom_aggregation.mojo",
};

// Zig coordinates external commands; Mojo remains the only database compiler.
// Track imports and the locked toolchain as inputs to each cached compilation.
fn compile(b: *std.Build, source: []const u8, output: []const u8, flags: []const []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "uv", "run", "--locked", "mojo", "build" });
    cmd.addArgs(flags);
    cmd.addArgs(&.{ "-I", "src" });
    cmd.addFileArg(b.path(source));
    cmd.addArg("-o");
    const result = cmd.addOutputFileArg(output);
    for (mojo_sources) |file| cmd.addFileInput(b.path(file));
    for ([_][]const u8{ "pyproject.toml", "uv.lock", ".python-version", ".zig-version" }) |file| {
        cmd.addFileInput(b.path(file));
    }
    return result;
}

fn runNative(b: *std.Build, executable: std.Build.LazyPath) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{ "uv", "run", "--locked" });
    cmd.addFileArg(executable);
    cmd.addArgs(b.args orelse &.{});
    return cmd;
}

pub fn build(b: *std.Build) void {
    const sync = b.addSystemCommand(&.{ "uv", "sync", "--locked" });
    const version = b.addSystemCommand(&.{ "uv", "run", "--locked", "mojo", "--version" });
    version.step.dependOn(&sync.step);
    b.step("setup", "Install the locked project-local Mojo toolchain").dependOn(&version.step);

    const cli = compile(b, "src/tsdb.mojo", "tsdb", &.{"-O3"});
    const install_cli = b.addInstallFileWithDir(cli, .bin, "tsdb");
    b.getInstallStep().dependOn(&install_cli.step);

    const tests = compile(b, "tests/tests.mojo", "tests", &.{"-O3"});
    const native = runNative(b, tests);
    b.step("test-native", "Run native TestSuite tests; forward flags after --").dependOn(&native.step);

    const benchmarks = compile(b, "benchmarks/benchmarks.mojo", "benchmarks", &.{"-O3"});
    const install_benchmarks = b.addInstallFileWithDir(benchmarks, .bin, "benchmarks");
    const python_tests = b.addSystemCommand(&.{ "uv", "run", "--locked", "python", "-m", "unittest", "discover", "-s", "tests", "-v" });
    python_tests.setEnvironmentVariable("TSDB_BINARY", b.getInstallPath(.bin, "tsdb"));
    python_tests.setEnvironmentVariable("TSDB_BENCHMARK_BINARY", b.getInstallPath(.bin, "benchmarks"));
    python_tests.step.dependOn(&install_cli.step);
    python_tests.step.dependOn(&install_benchmarks.step);
    python_tests.step.dependOn(&native.step);

    const example = b.addSystemCommand(&.{ "uv", "run", "--locked", "mojo", "-I", "src", "examples/custom_aggregation.mojo" });
    b.step("example", "Run the independent Spread aggregator").dependOn(&example.step);
    const test_step = b.step("test", "Run native, black-box, benchmark smoke tests, and example");
    test_step.dependOn(&python_tests.step);
    test_step.dependOn(&example.step);

    const demo = b.addSystemCommand(&.{ "uv", "run", "--locked", "bash", "scripts/demo.sh" });
    demo.setEnvironmentVariable("TSDB_BINARY", b.getInstallPath(.bin, "tsdb"));
    demo.step.dependOn(&install_cli.step);
    b.step("demo", "Run the greenhouse scenario in a temporary database").dependOn(&demo.step);

    const format = b.addSystemCommand(&.{ "uv", "run", "--locked", "mojo", "format" });
    format.addArgs(&mojo_sources);
    const zig_format = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "build.zig" });
    const format_step = b.step("format", "Format Mojo sources and build.zig");
    format_step.dependOn(&format.step);
    format_step.dependOn(&zig_format.step);

    const debug = compile(b, "src/tsdb.mojo", "tsdb-debug", &.{ "-O0", "-g" });
    const install_debug = b.addInstallFileWithDir(debug, .bin, "tsdb-debug");
    b.step("debug", "Build the CLI with -O0 and full debug information").dependOn(&install_debug.step);

    // Mojo 1.0 TestSuite reproduces a zero-size-access ASan report at -O0 on
    // our ARM64 host. -O1 passes without disabling sanitizer instrumentation.
    const asan = compile(b, "tests/tests.mojo", "tests-asan", &.{ "-O1", "-g", "--sanitize", "address" });
    const sanitizer_tests = runNative(b, asan);
    b.step("sanitize", "Run native tests under AddressSanitizer (-O1)").dependOn(&sanitizer_tests.step);

    const assembly = compile(b, "examples/custom_aggregation.mojo", "spread.s", &.{ "-O3", "--emit", "asm" });
    const llvm = compile(b, "examples/custom_aggregation.mojo", "spread.ll", &.{ "--emit", "llvm" });
    const install_assembly = b.addInstallFileWithDir(assembly, .prefix, "inspect/spread.s");
    const install_llvm = b.addInstallFileWithDir(llvm, .prefix, "inspect/spread.ll");
    const inspect = b.step("inspect", "Emit optimized assembly and unoptimized LLVM IR");
    inspect.dependOn(&install_assembly.step);
    inspect.dependOn(&install_llvm.step);

    const bench = b.addSystemCommand(&.{ "uv", "run", "--locked", "python", "scripts/benchmark.py" });
    bench.setEnvironmentVariable("TSDB_BENCHMARK_BINARY", b.getInstallPath(.bin, "benchmarks"));
    bench.addArgs(b.args orelse &.{});
    bench.step.dependOn(&install_benchmarks.step);
    b.step("bench", "Run five baselines; pass -- --points N to change size").dependOn(&bench.step);
}

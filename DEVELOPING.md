# Development toolchain

## Reproducible setup

Install [Zig 0.16.0](https://ziglang.org/download/) (also recorded in
`.zig-version`) and [uv](https://docs.astral.sh/uv/getting-started/installation/),
then run:

```sh
zig build setup
zig build test
```

The environment lives in ignored `.venv/`. No shell activation or global Mojo
installation is required. `build.zig` uses `uv run --locked` for compiler, formatter,
Python, and native test execution. The CLI tests inherit that environment, so
compiler-rejection tests use the same Mojo installation as the build.

- `pyproject.toml`: exact `mojo==1.0.0` dependency; this is an environment project,
  not a Python package containing the database.
- `uv.lock`: resolved dependency versions and distribution hashes, committed.
- `.python-version`: Python 3.13. The Python patch release is not pinned.
- `build.zig` tracks Mojo sources (including imported modules), toolchain files,
  and command arguments as inputs to cached compilation. Outputs live in
  `.zig-cache/`; executables are installed into `zig-out/bin/`.
- Zig is only the build coordinator. There are no Zig runtime dependencies,
  libraries, or database implementation files.

Validated locally with Zig 0.16.0, uv 0.7.11, and Mojo 1.0.0 (`ed45d567`)
on ARM64 Linux/WSL2.
CI is configured for Linux x86-64 and ARM64; its remote runs are separate from
local verification. macOS is not currently included in the CI matrix.

To update Mojo deliberately, change its exact dependency, run `uv lock`, then
`zig build setup test sanitize`. Review the lockfile and source compatibility changes
together. Routine builds use `--locked` so a stale lockfile fails rather than
silently resolving a new environment. To clean generated artifacts, remove
`zig-out/` and `.zig-cache/`; neither contains user databases or the environment.
The previous Make-based `build/` directory is no longer used and can be removed.

Use `zig build --help` to list tasks and `zig build --summary all` to inspect
cache hits. `zig build -p /some/prefix` changes the install location; demos,
benchmarks, and black-box tests receive the corresponding executable paths.
Native test and sanitizer binaries run directly from Zig's cache. Commands with
no generated output (tests, benchmarks, formatting) always run, even when their
compilation is cached. Avoid running `format` concurrently with compilation.

Mojo handles host CPU selection. Zig's generic `--release` option does not select
a Mojo optimization level; use the explicit default, `debug`, and `sanitize`
steps. Clear `.zig-cache/` if moving the checkout to a different CPU or replacing
the compiler outside the locked environment: those external changes are not
fully represented by the source-file cache keys.

Compiler defaults target the host CPU. A lockfile does not make binaries portable
across arbitrary CPUs or operating systems; build on the target platform or
choose and test an explicit deployment target before distributing executables.

## Tests and formatting

```sh
zig build test                                  # Native + Python black-box + example
zig build test-native -- --only test_buckets
zig build test-native -- --skip test_reference_model
zig build test-native -- --skip-all              # List discovered native tests
zig build format
```

`TestSuite.discover_tests[__functions_in_module()]()` discovers native tests by
the `test_` prefix using compiler reflection. `assert_raises` replaces manual
exception flags. Ordinary test failures remain nonzero exits. The Python tests
still cover independent-process persistence, corrupt files, Float64 bit round
trips, compile-time trait rejection, and now the benchmark harness.

Mojo 1.0's `mojo format` does **not** expose a `--check` flag. CI runs the official
formatter and then `git diff --exit-code -- '*.mojo' build.zig` instead. That
comparison is against the checked-out commit; locally, use `zig build format`
and review your diff. The format step also runs `zig fmt build.zig`.

## Debugging and memory checks

```sh
zig build debug
uv run --locked mojo debug zig-out/bin/tsdb-debug --help
# Or debug a range query against a database you have created:
uv run --locked mojo debug zig-out/bin/tsdb-debug range greenhouse.tsdb greenhouse.temperature 0 60
zig build sanitize
zig build sanitize -- --only test_reference_model
```

The release CLI uses `-O3`; `zig-out/bin/tsdb-debug` uses `-O0 -g`.
The cached `tests-asan` uses `-O1 -g --sanitize address`. These are distinct artifacts,
so creating a debug or sanitizer build never replaces the release executable.
The sanitizer target covers native tests, not the separate-process CLI suite.

### Why ASan uses -O1

On the tested ARM64 machine, Mojo 1.0's `TestSuite.generate_report` triggers an
AddressSanitizer **zero-size-access** report with `-O0`, in standard-library
Optional/Variant construction. This reproduces without any database code:

```mojo
from std.testing import TestSuite, assert_equal

def test_trivial() raises:
    assert_equal(1, 1)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

The complete database test suite passes with ASan at `-O1`. We use that setting
without disabling instrumentation or suppressing reports. This observation is
not a proof that every `-O0` sanitizer finding is a false positive; recheck this
specific reproducer when upgrading the toolchain. Sanitizers remain experimental
in Mojo 1.0.

The toolchain also supplies `mojo-lsp-server`, `mojo-lldb`, and `lldb-dap` under
`.venv/bin/`. Point your editor at the project environment rather than a different
global compiler. No editor-specific configuration is imposed on contributors.

## Inspect generated code

```sh
zig build inspect
```

- `zig-out/inspect/spread.s`: target assembly for the custom Spread example, using `-O3`.
- `zig-out/inspect/spread.ll`: **unoptimized** LLVM IR, as specified by `mojo build --emit llvm`.

These artifacts include runtime code as well as the example. Emitting them does
not itself prove that a particular loop vectorized or that every call inlined.
Inspect the relevant functions and pair any conclusion with measurements.

## Benchmark methodology

```sh
zig build bench                          # 10,000 points
zig build bench -- --points 1000
zig build bench -- --points 100000        # Reverse insertion is quadratic: expect longer runs
```

`scripts/benchmark.py` provides a fresh temporary journal path, prints OS,
compiler, and effective CPU target, and removes the fixture even on failure.
The native executable refuses existing paths. It supports 1–1,000,000 points;
the upper bound is a safety cap, not a recommended benchmark size.

Every fixture has one series, timestamps `0..n-1`, and values `timestamp % 100`.
The harness checks the expected sum and bucket totals before timing. Workloads
use `std.benchmark.run` with warmup, repeated measurements, and `keep` barriers.
Each reported iteration means a **complete operation**, not an individual point.

| Workload | Included in timed operation | Excluded |
| --- | --- | --- |
| Replay | File open/read, parsing, validation, index reconstruction, destruction | Fixture generation, process startup |
| Ordered insertion | Fresh engine, n ascending upserts, allocations, destruction | Journal writes, replay |
| Reverse insertion | Fresh engine, n descending upserts, column shifts, destruction | Journal writes, replay |
| Aggregate | Full-range Sum on a preloaded engine | Loading, setup, process startup |
| Downsample | Full-range Sum, width 100, result allocation/destruction, keep per bucket | Loading, setup, process startup |

The query closures explicitly borrow the preloaded database with `imm` captures:
no full database copy is needed to pass the workload to the benchmark library.
Insertion starts from an empty engine **each iteration**, avoiding the mistake
of benchmarking replacement writes after the first iteration.

Replay is a **warm filesystem-cache** measurement. This is not a cold-disk,
power-loss durability, or write-throughput benchmark. Reverse insertion is a
worst-case order, not a statistically random arrival distribution. Downsampling
includes an observation pass over its buckets to keep every result value alive.

Measurement windows target at least 0.1 seconds and at most roughly 0.5 seconds
per workload, with iteration caps (the minimum runtime takes precedence over
those caps). They are not hard deadlines: a single slow iteration can exceed
the window. Per-iteration timer and observation overhead
matter particularly for tiny data sets. Repeat measurements on an idle machine,
record the commit and machine configuration, and compare equivalent workloads.
Do not add unstable timing thresholds to correctness CI.

`zig build test` includes a 101-point benchmark smoke test (including a partial final
bucket), invalid-size rejection, and refusal to overwrite existing files.
The full benchmark run is for local investigation, not a published performance
claim or a comparison with another language.

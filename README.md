# A time-series database in Mojo

A small database built from scratch to learn **Mojo traits through a real project**.
The database, storage engine, journal parser, query engine, and CLI are all Mojo.
There is no SQLite, pandas, Python interop, or external database underneath it;
only Mojo's standard library. Python's standard library is used for black-box tests.

Tested on **Mojo 1.0.0 (`ed45d567`), 64-bit Linux**.

## Start here

```sh
zig build setup    # Install the locked Mojo 1.0.0 toolchain using uv
zig build          # Compile a native executable into zig-out/bin/tsdb
zig build demo     # Run a greenhouse-sensor scenario in a temporary database
zig build test     # Native tests, CLI/persistence tests, and custom-trait example
zig build example  # Run the independent Spread aggregator
```

Then open **[LEARNING.md](LEARNING.md)**. It connects the terminology to the
actual code and walks you through extending the database yourself.

Requires [Zig 0.16.0](https://ziglang.org/download/) and
[uv](https://docs.astral.sh/uv/getting-started/installation/).
Zig orchestrates the build; Mojo compiles all database code.
`pyproject.toml`, `uv.lock`, and `.python-version` pin the Mojo dependency and
Python minor version; uv manages the local `.venv`. All Mojo/Python invocations use
`uv run --locked`, including the Python tests' compiler subprocesses. There are
no third-party database libraries or Python dependencies in the database runtime.
To compile directly without the Zig build runner:
`mkdir -p zig-out/bin && uv run --locked mojo build tsdb.mojo -o zig-out/bin/tsdb`.

See **[DEVELOPING.md](DEVELOPING.md)** for filtered tests, debugging, sanitizers,
assembly/IR inspection, benchmarks, and toolchain updates.

```sh
zig build test-native -- --only test_buckets
zig build debug      # Build zig-out/bin/tsdb-debug with -O0 -g
zig build sanitize   # Run native tests with AddressSanitizer (-O1 -g)
zig build inspect    # Emit optimized assembly and unoptimized LLVM IR for Spread
zig build bench      # Five separate baseline workloads, 10,000 points each
```

## Create a database you can keep

Run these commands from this project directory, using a fresh database path:

```sh
./zig-out/bin/tsdb init greenhouse.tsdb
./zig-out/bin/tsdb import greenhouse.tsdb examples/greenhouse.tsv
./zig-out/bin/tsdb series greenhouse.tsdb
./zig-out/bin/tsdb range greenhouse.tsdb greenhouse.temperature 0 60
./zig-out/bin/tsdb aggregate greenhouse.tsdb greenhouse.temperature 0 60 mean
./zig-out/bin/tsdb downsample greenhouse.tsdb greenhouse.temperature 0 60 20 mean
```

The mean is `21.0`. The downsample output is:

```text
bucket_start	count	value
0	2	19.5
20	2	22.0
40	2	21.5
```

Add a late reading, then correct an existing reading:

```sh
./zig-out/bin/tsdb put greenhouse.tsdb greenhouse.temperature 15 22
./zig-out/bin/tsdb put greenhouse.tsdb greenhouse.temperature 30 24
./zig-out/bin/tsdb range greenhouse.tsdb greenhouse.temperature 10 40
```

Every command is a separate process: these queries exercise persistence and
replay, not just an object left in memory. `init` refuses an existing path;
it does not reset a database. `zig build demo` uses a temporary file and removes it.

## Commands

```text
init PATH
put PATH SERIES TIMESTAMP VALUE
import PATH INPUT.tsv
series PATH
range PATH SERIES START END
aggregate PATH SERIES START END OP
downsample PATH SERIES START END WIDTH OP
```

`OP` is `sum`, `mean`, `min`, `max`, or `count`. Output is tab-separated.
`./zig-out/bin/tsdb --help` shows the same command reference. Errors exit nonzero.

### Exact data semantics

- Each series contains integer timestamps and `Float64` values.
- Timestamp units are your choice: seconds, milliseconds, or another consistent
  tick unit. There is no date/time parsing or automatic unit conversion.
- Stored timestamps satisfy `0 <= t < 9223372036854775807`. The excluded maximum
  signed 64-bit integer is reserved as an exclusive upper query bound.
- Ranges are **half-open**: `[START, END)`. `START == END` is a valid empty range.
- Out-of-order writes are allowed. Rewriting `(series, timestamp)` **replaces**
  its value: last journal record wins, not duplicate accumulation.
- Names contain 1–128 ASCII letters, digits, dots, underscores, or hyphens.
- Inputs must be finite numbers: NaN and infinity are rejected.
- A missing series returns an empty result, not an error.
- Empty aggregate output is `count=0, value=null`, including the `count` operation.
  The native `AggregateResult.value` is only meaningful when `count > 0`.
- Downsampling aligns buckets to **query START**, not Unix epoch zero.
  Buckets are half-open, empty buckets are omitted, and the last bucket can be
  shorter than WIDTH. WIDTH must be positive. Gaps are not filled with zero.
- `series` lists names in first-insertion order, with counts of unique timestamps.

### Import format

UTF-8/ASCII text with **no header**, tab delimiters, and an LF newline after every
record, including the last. Blank rows are errors. Example:

```text
greenhouse.temperature	0	18
greenhouse.temperature	10	21
```

Import validates the complete input before writing anything. Invalid input leaves
the journal unchanged. Import is **not a transaction**: an IO failure during
appending can leave a successfully written prefix.

## How it works

```text
CLI (tsdb.mojo)
  └─ Database (storage.mojo)
       ├─ versioned append-only journal: source of truth
       └─ Engine (engine.mojo)
            ├─ Dict[String, Int]: series name → position
            └─ List[Series]
                 ├─ List[Int]: sorted timestamps
                 └─ List[Float64]: corresponding values
                      └─ aggregate[A: Aggregator] / downsample[A: Aggregator]
```

**Writes:** validate → append and close journal → update in-memory columns.
**Open:** check header → validate records → replay upserts into a fresh engine.
**Queries:** two binary searches find the range, then scan matching values.

The journal begins with `MOJO_TSDB_V1\n`, followed by the same TSV record format.
It retains old versions of overwritten points. Normal command-to-command
persistence is tested, including exact Float64 bit round trips for sampled values.

For a series containing `n` unique points, and a query matching `k` points:

| Operation after opening | Cost |
| --- | --- |
| Find series | Expected O(1) dictionary lookup |
| Locate range | O(log n) |
| Range / aggregate / downsample | O(log n + k) |
| Ordered insert / existing timestamp replacement | O(log n), plus amortized append cost |
| Out-of-order insert | O(n), because columns shift |

The engine is columnar so timestamp search does not need to read the values.
Aggregation scans the values without materializing `Point` objects. Returned
range rows and buckets are materialized lists.

**CLI startup is not included in those costs.** Every invocation reads the entire
journal and rebuilds the index. Large out-of-order replay can be quadratic.
Import and replay also temporarily hold parsed records in memory.

## Where to read the code

| File | Purpose |
| --- | --- |
| `aggregations.mojo` | Trait contract and five concrete accumulator types |
| `engine.mojo` | Columnar storage, binary search, upserts, generic queries |
| `storage.mojo` | Journal creation/replay, strict record parsing, persistent writes |
| `tsdb.mojo` | CLI and runtime-name → compile-time-type dispatch |
| `examples/custom_aggregation.mojo` | Add Spread without touching the engine |
| `tests.mojo` | Native TestSuite discovery, reference-model checks, custom aggregator |
| `tests/test_cli.py` | Separate-process persistence, invalid inputs, compiler rejection |
| `LEARNING.md` | Hands-on trait and ownership labs |
| `benchmarks.mojo` | Replay, insertion, aggregation, and downsampling baselines |
| `tests/test_benchmarks.py` | Benchmark harness correctness and file-safety smoke tests |
| `DEVELOPING.md` | Locked toolchain, debugging, sanitizers, benchmark methodology |
| `build.zig` | Build graph, cached Mojo compilation, and development tasks |
| `.github/workflows/ci.yml` | Linux x86-64 and ARM64 checks using the same Zig build steps |

## Deliberate boundaries

This is a **learning database, not a production database server**.

- **One process at a time per file.** No locking, concurrency, isolation, or safe
  concurrent initialization. Do not read while another process is writing.
- Closing a file flushes userspace buffers; there is **no explicit fsync**,
  power-loss durability guarantee, atomic append guarantee, or batch transaction.
- An incomplete final row or malformed record makes opening fail. Nothing is
  silently discarded or repaired. Preserve the original file before attempting
  manual recovery. Syntactically valid corruption is not detected: no checksums.
- On a write/close failure, commit status can be uncertain. Stop using that
  instance and inspect/reopen the file rather than assuming rollback.
- All current points fit in RAM; the journal grows without compaction. No retention,
  compression, file index, SQL, tags, network protocol, or multi-series joins.
- Numeric aggregates use ordinary Float64 arithmetic. Rounding, cancellation,
  and aggregate overflow remain possible even with finite inputs. Means are
  sample-weighted, not time-weighted. No compensated sum or financial precision.
- No explicit SIMD or GPU acceleration. Baseline benchmarks now separate replay,
  insertion, and in-memory queries; they do not establish a speedup over other
  languages or databases.

Some installations print a Crashpad initialization warning when invoking the Mojo
compiler. On the tested machine it did not prevent compilation or passing tests.

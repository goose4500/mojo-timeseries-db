# Learn traits by extending your database

Our project is a greenhouse monitor: temperature and humidity readings arrive
over time. We need to save them, query an interval, and summarize what happened.

Start with `zig build demo`. Then work through these labs in order. You do not need to
understand every file before changing something useful.

## 1. Understand the actual data first

The point `(10, 21.0)` in `greenhouse.temperature` means “at time 10, the reading
was 21 degrees.” The database does not encode the unit; our application supplies it.

Create the persistent example using the commands in `README.md`. Try:

```sh
./zig-out/bin/tsdb range greenhouse.tsdb greenhouse.temperature 10 30
```

You get timestamps 10 and 20, **not** 30: `[10, 30)` includes its left endpoint
and excludes its right endpoint. This makes adjacent time buckets non-overlapping.

Now write a new value at timestamp 20 and query again. This is an **upsert**:
insert when absent, replace when present. The journal retains both writes, but the
current index exposes only the latest value at that timestamp.

**Find it:** `Series.put` and `Series.lower_bound` in `engine.mojo`.

**Experiment:** insert time 15 after time 50. Why are results still sorted?
Which part of insertion must move data, and why is that expensive at large scale?

## 2. Name the capability: a trait

Open `aggregations.mojo`:

```mojo
trait Aggregator(Defaultable, Deinitable):
    def add(mut self, value: Float64):
        ...

    def finish(self) -> Float64:
        ...
```

**Trait:** a compile-time contract describing capabilities a type must provide.
It is not an accumulator object and it does not store any running total.

Our query engine needs to:

1. Construct an empty accumulator.
2. Feed it readings using `add`.
3. Ask for its answer using `finish`.
4. Let the accumulator's lifetime end normally.

That is why the trait inherits two standard-library capabilities:

- **`Defaultable`** guarantees a no-argument constructor, so `A()` is legal.
- **`Deinitable`** permits ordinary destruction when the accumulator leaves scope.
  The Mojo 1.0 compiler requires this lifecycle guarantee in our generic code.

This is **trait composition**: a contract built from smaller contracts. These
names and examples are tested against this project's installed Mojo 1.0.0;
online/nightly documentation may show different lifecycle names.

The contract also has a rule the compiler cannot prove: `finish` is called only
after at least one `add`. The engine enforces that rule by checking the count.
This is why an empty mean does not divide by zero.

## 3. Implement the contract with a struct

In the same file, examine `Sum`:

```mojo
struct Sum(Aggregator):
    var total: Float64

    def __init__(out self):
        self.total = 0

    def add(mut self, value: Float64):
        self.total += value

    def finish(self) -> Float64:
        return self.total
```

**Struct:** a concrete type with actual data and methods.

**Conformance:** `Sum(Aggregator)` declares that Sum fulfills the Aggregator
contract. The compiler checks the required method signatures. It does not prove
that a method named Sum actually calculates a sum.

Sum does not inherit a running-total field or method bodies from Aggregator.
This is capability sharing, not a base-class implementation hierarchy.

Compare `Mean`: it stores both a total and a count. Same capability, different
state and algorithm. The query loop does not need to know that difference.

**Experiment:** temporarily rename `Sum.finish` to `answer`, then run `zig build`.
Read the compiler error and restore the method. You have just tested a contract,
not encountered a missing method during a live database query. `zig build test` also
includes an isolated compile-fail test for this, without modifying your files.

## 4. The leverage: one generic algorithm, many concrete types

Find `Series.aggregate` in `engine.mojo`. Its core is:

```mojo
var accumulator = A()
for i in range(low, high):
    accumulator.add(self.values[i])
```

Its declaration includes **`[A: Aggregator]`**.

- **Generic code:** code written in terms of a type parameter rather than one
  fixed type.
- **Constraint:** `: Aggregator` restricts A to types satisfying that contract.
- **Compile-time parameter:** A is selected while compiling an instantiation.
- **Runtime arguments:** the series name, start time, end time, and values vary
  when the executable runs.

Compare these calls:

```mojo
db.aggregate[Sum]("greenhouse.temperature", 0, 60)
db.aggregate[Mean]("greenhouse.temperature", 0, 60)
```

Square brackets select the compile-time type. Parentheses supply runtime values.
The same source algorithm can be specialized for different types. The compiler
knows which `add` and `finish` it is calling and can inline them; a virtual method
table is not required by this design. This enables optimization, but does not by
itself prove a speedup—measurement comes later.

**Find the boundary:** the CLI receives a runtime string such as `"mean"`.
In `tsdb.mojo`, ordinary branches choose among already compiled
`dispatch[Mean]`, `dispatch[Sum]`, and other instantiations. Arbitrary new types
cannot be loaded merely by writing a new string on the command line.

## 5. Add a useful capability implementation: temperature swing

```sh
zig build example
```

Open `examples/custom_aggregation.mojo`. `Spread` calculates maximum minus
minimum, using Minimum and Maximum as fields. This is **composition of values**:
the struct contains and delegates to two accumulator objects.

Expected output:

```text
Temperature swing: 7.0 degrees
Bucket 0: swing = 3.0
Bucket 20: swing = 6.0
```

The example passes Spread to both `aggregate` and `downsample`. Neither the
engine nor storage module imports Spread. That is the extension point working:
**new behavior without a new query algorithm**.

### Your first implementation: Above22

Make an `Above22(Aggregator)` that counts readings strictly greater than 22:

1. Store an integer count, initialized to zero.
2. In `add`, increment it only when `value > 22`.
3. In `finish`, return the count converted to Float64.
4. Query the four readings in the custom example using `[Above22]`.
5. Add a native test; the answer for those readings should be `1.0`.
6. Try it with downsampling. The two buckets should yield `0.0` and `1.0`.

You should not have to modify `engine.mojo` or `storage.mojo`.

To expose it through the CLI, add its import and an operation-name branch in
`tsdb.mojo`, following the existing `Count` branch. This is separate from making
it work with the generic engine.

**Next experiment:** make the threshold a compile-time parameter of your struct,
rather than fixing it at 22. How is that different from taking a user-selected
threshold at runtime? Our current default-construction contract deliberately
makes runtime-configured aggregators a future API design exercise.

## 6. Ownership terminology, anchored in this code

Mojo also makes data movement and access explicit:

| Syntax / trait | Meaning here | Example |
| --- | --- | --- |
| `out self` | Initialize previously uninitialized storage | Constructors |
| `mut self` | Exclusive mutable access to an existing value | `add`, `put` |
| Plain `self` | Read-only borrowed access | `finish`, `lower_bound` |
| `Movable` | Ownership can transfer to a new location | Series stored in a List |
| `Copyable` | A separate copy can be constructed | Small Point and Bucket results |
| `result^` | Transfer ownership from a local value | Returning result lists |

Engine, Database, and Series are movable but not declared copyable. Accidentally
copying an entire database's columns should not be a routine operation. Query
results, by contrast, are small independent values designed to be copied.

**Experiment:** try to copy an Engine, then compare with copying a Point.
Distinguish ownership transfer from borrowing: calling a read-only query does not
hand away the entire database. Also inspect indexed iteration over Series in the
CLI: we avoid requiring every Series to be copyable just to list its name.

## 7. From a learning database toward a larger system

The current trait is intentionally narrow. We did not add a StorageBackend trait
with just one implementation merely to demonstrate more syntax.

Useful next projects, each with a concrete reason:

1. **Stable numerical aggregation.** Implement a compensated sum and compare it
   with Sum on cancellation-heavy data. Same query engine, different accuracy.
2. **Variance.** Implement a streaming variance accumulator. Decide and document
   population versus sample variance and behavior with a single reading.
3. **Long-running ingestion.** Keep one Database open instead of replaying the
   journal on every CLI command. Measure ingestion versus startup separately.
4. **Compaction.** Rewrite only current points to a new journal. Design safe
   replacement and crash recovery before deleting any old data.
5. **Compression.** Compare uncompressed timestamps with delta encoding. Once two
   real encodings exist, derive a Codec trait from what both actually need.
6. **Parallel aggregation.** Add a merge capability for partial accumulators.
   Mean must merge totals and counts—not average averages. Floating-point merge
   order affects reproducibility. Do not assume all Aggregators are mergeable.
7. **SIMD scans.** Benchmark a specialized contiguous-column sum against the
   scalar generic loop. Distinguish measured vectorization from assumed speed.

Before optimizing, define correctness. `zig build test` already checks shuffled
upserts against a dense reference model, persistence across processes, exact
sampled float round trips, empty queries, bucket boundaries, corrupt journals,
and an independently defined Aggregator.

**Recommended first session:** run the demo, read Sum, break its conformance once,
restore it, then build Above22. That is enough to make traits tangible.

Reference: [Mojo traits manual](https://mojolang.org/docs/manual/traits).

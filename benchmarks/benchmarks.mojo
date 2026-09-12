"""Isolated database baselines; run with `zig build bench`."""

from std.benchmark import run
from std.benchmark.compiler import keep
from std.sys import argv
from std.testing import assert_equal
from aggregations import Sum
from engine import Engine
from storage import Database, create_database, parse_timestamp


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: benchmarks NEW_JOURNAL_PATH POINT_COUNT")
    var path = args[1]
    var n = parse_timestamp(args[2])
    if n < 1 or n > 1000000:
        raise Error("POINT_COUNT must be between 1 and 1000000")
    # Caller provides a fresh temporary path; never overwrite existing data.
    create_database(path)
    with open(path, "a") as file:
        for i in range(n):
            file.write(String("sensor\t", i, "\t", i % 100, "\n"))
    var loaded = Database(path)
    var expected: Float64 = 0
    for i in range(n):
        expected += Float64(i % 100)
    assert_equal(loaded.engine.aggregate[Sum]("sensor", 0, n).value, expected)
    var check = loaded.engine.downsample[Sum]("sensor", 0, n, 100)
    var bucket_total: Float64 = 0
    for bucket in check:
        bucket_total += bucket.value
    assert_equal(bucket_total, expected)
    assert_equal(len(check), (n + 99) // 100)

    def replay() raises {imm path}:
        var database = Database(path)
        keep(len(database.engine.series[0].timestamps))

    def ordered_insert() raises {imm n}:
        var engine = Engine()
        for i in range(n):
            engine.put("sensor", i, Float64(i % 100))
        keep(engine.series[0].values[n - 1])
        keep(len(engine.series[0].timestamps))

    def reverse_insert() raises {imm n}:
        var engine = Engine()
        for i in range(n):
            var timestamp = n - 1 - i
            engine.put("sensor", timestamp, Float64(timestamp % 100))
        keep(engine.series[0].values[n - 1])
        keep(len(engine.series[0].timestamps))

    def aggregate() raises {imm loaded, imm n}:
        var result = loaded.engine.aggregate[Sum]("sensor", 0, n)
        keep(result.value)
        keep(result.count)

    def downsample() raises {imm loaded, imm n}:
        var result = loaded.engine.downsample[Sum]("sensor", 0, n, 100)
        # Make every bucket value observable, not only the result length.
        for bucket in result:
            keep(bucket.value)
            keep(bucket.count)
        keep(len(result))

    print(
        String("Points per iteration: ", n, "; Float64 sum; bucket width: 100")
    )
    print("One iteration is one complete operation, not one point.")
    print("Replay (warm filesystem cache; read, parse, rebuild, destroy):")
    var replay_report = run(replay, 1, 1000, 0.1, 0.5, 1)
    replay_report.print()
    print(
        "Ordered insertion (fresh in-memory engine, including"
        " allocation/destruction):"
    )
    var ordered_report = run(ordered_insert, 1, 1000, 0.1, 0.5, 1)
    ordered_report.print()
    print(
        "Reverse-order insertion (worst-case shifts; fresh engine; no journal"
        " IO):"
    )
    var reverse_report = run(reverse_insert, 1, 1000, 0.1, 0.5, 1)
    reverse_report.print()
    print("In-memory aggregation (preloaded engine, no replay):")
    var aggregate_report = run(aggregate, 1, 10000, 0.1, 0.5, 1)
    aggregate_report.print()
    print(
        "Downsampling (preloaded engine; includes result allocation/destruction"
        " and keep per bucket):"
    )
    var downsample_report = run(downsample, 1, 10000, 0.1, 0.5, 1)
    downsample_report.print()

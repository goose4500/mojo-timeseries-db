"""CLI for the learning database. Run with --help for command syntax."""

from std.sys import argv
from aggregations import Aggregator, Sum, Mean, Minimum, Maximum, Count
from engine import Engine
from storage import Database, create_database, parse_timestamp


def usage():
    print(
        "Mojo time-series database (single process, signed 64-bit timestamps)"
    )
    print("  tsdb init PATH")
    print("  tsdb put PATH SERIES TIMESTAMP VALUE")
    print("  tsdb import PATH INPUT.tsv")
    print("  tsdb series PATH")
    print("  tsdb range PATH SERIES START END")
    print("  tsdb aggregate PATH SERIES START END OP")
    print("  tsdb downsample PATH SERIES START END WIDTH OP")
    print("OP: sum | mean | min | max | count")
    print("Ranges are [START, END); buckets align to START.")
    print(
        "Stored timestamps: 0 <= t < 9223372036854775807; END may equal that"
        " limit."
    )


def print_aggregate[
    A: Aggregator
](engine: Engine, name: String, start: Int, end: Int) raises:
    var result = engine.aggregate[A](name, start, end)
    print("count\tvalue")
    if result.count == 0:
        print("0\tnull")
    else:
        print(String(result.count, "\t", result.value))


def print_buckets[
    A: Aggregator
](engine: Engine, name: String, start: Int, end: Int, width: Int) raises:
    var buckets = engine.downsample[A](name, start, end, width)
    print("bucket_start\tcount\tvalue")
    for bucket in buckets:
        print(String(bucket.start, "\t", bucket.count, "\t", bucket.value))


def dispatch[
    A: Aggregator
](
    engine: Engine,
    name: String,
    start: Int,
    end: Int,
    width: Int,
    bucketed: Bool,
) raises:
    if bucketed:
        print_buckets[A](engine, name, start, end, width)
    else:
        print_aggregate[A](engine, name, start, end)


def main() raises:
    var args = argv()
    if len(args) == 1 or (len(args) == 2 and args[1] == "--help"):
        usage()
        return
    if len(args) < 3:
        raise Error("expected command and database path; see --help")
    var command = args[1]
    var path = args[2]
    if command == "init":
        if len(args) != 3:
            raise Error("usage: tsdb init PATH")
        create_database(path)
        print("created " + path)
    elif command == "put":
        if len(args) != 6:
            raise Error("usage: tsdb put PATH SERIES TIMESTAMP VALUE")
        var timestamp = parse_timestamp(args[4])
        var value = Float64(args[5])
        var database = Database(path)
        database.put(args[3], timestamp, value)
        print("ok")
    elif command == "import":
        if len(args) != 4:
            raise Error("usage: tsdb import PATH INPUT.tsv")
        var database = Database(path)
        print(String("imported ", database.import_tsv(args[3]), " records"))
    elif command == "series":
        if len(args) != 3:
            raise Error("usage: tsdb series PATH")
        var database = Database(path)
        print("series\tpoints")
        for i in range(len(database.engine.series)):
            print(
                String(
                    database.engine.series[i].name,
                    "\t",
                    len(database.engine.series[i].timestamps),
                )
            )
    elif command == "range":
        if len(args) != 6:
            raise Error("usage: tsdb range PATH SERIES START END")
        var database = Database(path)
        var points = database.engine.query(
            args[3], parse_timestamp(args[4]), parse_timestamp(args[5])
        )
        print("timestamp\tvalue")
        for point in points:
            print(String(point.timestamp, "\t", point.value))
    elif command == "aggregate" or command == "downsample":
        var bucketed = command == "downsample"
        var expected = 7
        if bucketed:
            expected = 8
        if len(args) != expected:
            raise Error("wrong argument count; see --help")
        var start = parse_timestamp(args[4])
        var end = parse_timestamp(args[5])
        var width = 0
        if bucketed:
            width = parse_timestamp(args[6])
        var op = args[expected - 1]
        var database = Database(path)
        if op == "sum":
            dispatch[Sum](database.engine, args[3], start, end, width, bucketed)
        elif op == "mean":
            dispatch[Mean](
                database.engine, args[3], start, end, width, bucketed
            )
        elif op == "min":
            dispatch[Minimum](
                database.engine, args[3], start, end, width, bucketed
            )
        elif op == "max":
            dispatch[Maximum](
                database.engine, args[3], start, end, width, bucketed
            )
        elif op == "count":
            dispatch[Count](
                database.engine, args[3], start, end, width, bucketed
            )
        else:
            raise Error("unknown aggregation: " + op)
    else:
        raise Error("unknown command: " + command)

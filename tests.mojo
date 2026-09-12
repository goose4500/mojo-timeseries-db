"""Native Mojo tests, including a new trait implementation unknown to engine."""

from std.testing import TestSuite, assert_equal, assert_raises
from aggregations import Aggregator, Sum, Mean, Minimum, Maximum, Count
from engine import Engine, validate_point, validate_range, MAX_TIME_BOUND
from storage import parse_records, parse_timestamp


struct Spread(Aggregator):
    """User-defined aggregator, composed from two existing concrete types."""

    var low: Minimum
    var high: Maximum

    def __init__(out self):
        self.low = Minimum()
        self.high = Maximum()

    def add(mut self, value: Float64):
        self.low.add(value)
        self.high.add(value)

    def finish(self) -> Float64:
        return self.high.finish() - self.low.finish()


def test_ordering_and_upserts() raises:
    var db = Engine()
    db.put("sensor.room", 30, 3)
    db.put("sensor.room", 10, 1)
    db.put("sensor.room", 20, 2)
    db.put("sensor.room", 20, 8)
    db.put("other", 20, 99)
    var points = db.query("sensor.room", 0, 40)
    assert_equal(len(points), 3)
    assert_equal(points[0].timestamp, 10)
    assert_equal(points[1].timestamp, 20)
    assert_equal(points[1].value, Float64(8))
    assert_equal(points[2].timestamp, 30)
    assert_equal(len(db.query("sensor.room", 10, 30)), 2)
    assert_equal(len(db.query("sensor.room", 20, 20)), 0)
    assert_equal(len(db.query("missing", 0, 40)), 0)
    assert_equal(db.query("other", 0, 40)[0].value, Float64(99))


def test_aggregators() raises:
    var db = Engine()
    db.put("cpu", 0, -5)
    db.put("cpu", 10, 2)
    db.put("cpu", 20, 9)
    assert_equal(db.aggregate[Sum]("cpu", 0, 21).value, Float64(6))
    assert_equal(db.aggregate[Mean]("cpu", 0, 21).value, Float64(2))
    assert_equal(db.aggregate[Minimum]("cpu", 0, 21).value, Float64(-5))
    assert_equal(db.aggregate[Maximum]("cpu", 0, 21).value, Float64(9))
    assert_equal(db.aggregate[Count]("cpu", 0, 21).value, Float64(3))
    assert_equal(db.aggregate[Sum]("cpu", 0, 21).count, 3)
    assert_equal(db.aggregate[Mean]("cpu", 10, 20).value, Float64(2))
    assert_equal(db.aggregate[Mean]("cpu", 30, 40).count, 0)
    assert_equal(db.aggregate[Mean]("absent", 0, 40).count, 0)
    # Neither Engine nor Series imports or names Spread.
    assert_equal(db.aggregate[Spread]("cpu", 0, 21).value, Float64(14))
    assert_equal(db.aggregate[Spread]("cpu", 10, 20).value, Float64(0))
    assert_equal(db.aggregate[Maximum]("cpu", 0, 1).value, Float64(-5))
    assert_equal(db.aggregate[Minimum]("cpu", 20, 21).value, Float64(9))


def test_buckets() raises:
    var db = Engine()
    db.put("cpu", 5, 2)
    db.put("cpu", 14, 4)
    db.put("cpu", 15, 10)
    db.put("cpu", 35, 20)
    db.put("cpu", 40, 100)
    var buckets = db.downsample[Mean]("cpu", 5, 40, 10)
    assert_equal(len(buckets), 3)
    assert_equal(buckets[0].start, 5)
    assert_equal(buckets[0].count, 2)
    assert_equal(buckets[0].value, Float64(3))
    assert_equal(buckets[1].start, 15)
    assert_equal(buckets[1].value, Float64(10))
    assert_equal(buckets[2].start, 35)
    assert_equal(buckets[2].value, Float64(20))
    assert_equal(len(db.downsample[Sum]("cpu", 5, 5, 10)), 0)
    assert_equal(len(db.downsample[Sum]("missing", 0, 50, 10)), 0)
    var spread = db.downsample[Spread]("cpu", 5, 40, 10)
    assert_equal(spread[0].value, Float64(2))
    db.put("edge", MAX_TIME_BOUND - 1, 7)
    var edge = db.downsample[Sum](
        "edge", MAX_TIME_BOUND - 5, MAX_TIME_BOUND, 10
    )
    assert_equal(len(edge), 1)
    assert_equal(edge[0].start, MAX_TIME_BOUND - 5)
    assert_equal(edge[0].value, Float64(7))


def test_validation() raises:
    var bad_names: List[String] = ["", "a b", "a\tb", "a\nb", "café"]
    for name in bad_names:
        with assert_raises():
            validate_point(name, 0, 1)
    with assert_raises(contains="timestamp"):
        validate_point("ok", -1, 1)
    with assert_raises():
        validate_range(5, 4)
    var db = Engine()
    with assert_raises():
        _ = db.downsample[Sum]("missing", 0, 10, 0)
    assert_equal(parse_timestamp("0"), 0)
    assert_equal(parse_timestamp("9223372036854775807"), MAX_TIME_BOUND)
    var invalid: List[String] = [
        "-1",
        "+1",
        "1.5",
        "",
        " 1",
        "1x",
        "9223372036854775808",
    ]
    for text in invalid:
        with assert_raises():
            _ = parse_timestamp(text)


def test_record_parser() raises:
    var records = parse_records("cpu\t10\t1.25\ncpu\t20\t-2.5\n")
    assert_equal(len(records), 2)
    assert_equal(records[1].timestamp, 20)
    assert_equal(records[1].value, Float64(-2.5))
    assert_equal(len(parse_records("")), 0)
    var bad: List[String] = [
        "cpu\t10\t1",
        "cpu\t10\n",
        "cpu\tx\t1\n",
        "cpu\t0\tnan\n",
        "cpu\t0\tinf\n",
        "cpu\t0\t1junk\n",
        "\n",
        "cpu\t0\t\n",
        "cpu\t0\t1\textra\n",
    ]
    for text in bad:
        with assert_raises():
            _ = parse_records(text)


def test_reference_model() raises:
    # Deterministic shuffled upserts checked against an independent dense model.
    var db = Engine()
    var expected = List[Float64]()
    var present = List[Bool]()
    for _ in range(97):
        expected.append(0)
        present.append(False)
    var seed = 7
    for i in range(1000):
        seed = (seed * 37 + 11) % 997
        var timestamp = seed % 97
        var value = Float64(i - 500)
        db.put("random", timestamp, value)
        expected[timestamp] = value
        present[timestamp] = True
    for start in range(0, 97, 7):
        for end in range(start, 98, 9):
            var points = db.query("random", start, end)
            var count = 0
            var total: Float64 = 0
            for timestamp in range(start, end):
                if present[timestamp]:
                    assert_equal(points[count].timestamp, timestamp)
                    assert_equal(points[count].value, expected[timestamp])
                    total += expected[timestamp]
                    count += 1
            assert_equal(len(points), count)
            var result = db.aggregate[Sum]("random", start, end)
            assert_equal(result.count, count)
            assert_equal(result.value, total)
            var buckets = db.downsample[Sum]("random", start, end, 5)
            var bucket_count = 0
            var bucket_sum: Float64 = 0
            for bucket in buckets:
                var expected_count = 0
                var expected_sum: Float64 = 0
                for timestamp in range(
                    bucket.start, min(bucket.start + 5, end)
                ):
                    if present[timestamp]:
                        expected_count += 1
                        expected_sum += expected[timestamp]
                assert_equal(bucket.count, expected_count)
                assert_equal(bucket.value, expected_sum)
                bucket_count += bucket.count
                bucket_sum += bucket.value
            assert_equal(bucket_count, count)
            assert_equal(bucket_sum, total)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

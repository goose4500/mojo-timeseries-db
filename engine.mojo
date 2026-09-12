"""In-memory TSDB: one sorted pair of columns per series, no filesystem IO."""

from std.collections import Dict
from std.math import isfinite
from aggregations import Aggregator


# Reserved as an exclusive upper query bound so every stored point is queryable.
comptime MAX_TIME_BOUND = 9223372036854775807


@fieldwise_init
struct Point(Copyable, Movable):
    var timestamp: Int
    var value: Float64


@fieldwise_init
struct AggregateResult(Copyable, Movable):
    """value is meaningful only when count > 0 (empty results are not zero)."""

    var count: Int
    var value: Float64


@fieldwise_init
struct Bucket(Copyable, Movable):
    var start: Int
    var count: Int
    var value: Float64


def validate_name(name: String) raises:
    if name.byte_length() == 0 or name.byte_length() > 128:
        raise Error("series name must contain 1..128 ASCII characters")
    for char in name.as_bytes():
        if not (
            (char >= 97 and char <= 122)
            or (char >= 65 and char <= 90)
            or (char >= 48 and char <= 57)
            or char == 95
            or char == 45
            or char == 46
        ):
            raise Error("series name may contain only letters, digits, _, -, .")


def validate_point(name: String, timestamp: Int, value: Float64) raises:
    validate_name(name)
    if timestamp < 0 or timestamp >= MAX_TIME_BOUND:
        raise Error("timestamp requires 0 <= t < 9223372036854775807")
    if not isfinite(value):
        raise Error("value must be finite")


def validate_range(start: Int, end: Int) raises:
    if start < 0 or end < start:
        raise Error("range requires 0 <= start <= end")


struct Series(Movable):
    """Structure of arrays: timestamp search need not load measurement values.
    """

    var name: String
    var timestamps: List[Int]
    var values: List[Float64]

    def __init__(out self, name: String):
        self.name = name
        self.timestamps = List[Int]()
        self.values = List[Float64]()

    def lower_bound(self, timestamp: Int) -> Int:
        """First index whose timestamp is >= the requested timestamp."""
        var low = 0
        var high = len(self.timestamps)
        while low < high:
            var mid = low + (high - low) // 2
            if self.timestamps[mid] < timestamp:
                low = mid + 1
            else:
                high = mid
        return low

    def put(mut self, timestamp: Int, value: Float64):
        var index = self.lower_bound(timestamp)
        if index < len(self.timestamps) and self.timestamps[index] == timestamp:
            self.values[index] = value
        else:
            self.timestamps.insert(index, timestamp)
            self.values.insert(index, value)

    def aggregate[A: Aggregator](self, start: Int, end: Int) -> AggregateResult:
        var low = self.lower_bound(start)
        var high = self.lower_bound(end)
        # A is a compile-time type parameter, not a runtime object hierarchy.
        var accumulator = A()
        for i in range(low, high):
            accumulator.add(self.values[i])
        var value: Float64 = 0
        if high > low:
            value = accumulator.finish()
        return AggregateResult(high - low, value)

    def downsample[
        A: Aggregator
    ](self, start: Int, end: Int, width: Int) -> List[Bucket]:
        var result = List[Bucket]()
        var i = self.lower_bound(start)
        var high = self.lower_bound(end)
        while i < high:
            # Align to query start, skip empty buckets, avoid start+width overflow.
            var bucket_id = (self.timestamps[i] - start) // width
            var bucket_start = start + bucket_id * width
            var accumulator = A()
            var count = 0
            while i < high:
                if (self.timestamps[i] - start) // width != bucket_id:
                    break
                accumulator.add(self.values[i])
                count += 1
                i += 1
            result.append(Bucket(bucket_start, count, accumulator.finish()))
        return result^


struct Engine(Movable):
    var series: List[Series]
    var index: Dict[String, Int]

    def __init__(out self):
        self.series = List[Series]()
        self.index = Dict[String, Int]()

    def put(mut self, name: String, timestamp: Int, value: Float64) raises:
        validate_point(name, timestamp, value)
        if name not in self.index:
            var position = len(self.series)
            self.series.append(Series(name))
            self.index[name] = position
        self.series[self.index[name]].put(timestamp, value)

    def query(self, name: String, start: Int, end: Int) raises -> List[Point]:
        validate_name(name)
        validate_range(start, end)
        var result = List[Point]()
        if name in self.index:
            var position = self.index[name]
            var low = self.series[position].lower_bound(start)
            var high = self.series[position].lower_bound(end)
            for i in range(low, high):
                result.append(
                    Point(
                        self.series[position].timestamps[i],
                        self.series[position].values[i],
                    )
                )
        return result^

    def aggregate[
        A: Aggregator
    ](self, name: String, start: Int, end: Int) raises -> AggregateResult:
        validate_name(name)
        validate_range(start, end)
        if name not in self.index:
            return AggregateResult(0, 0)
        return self.series[self.index[name]].aggregate[A](start, end)

    def downsample[
        A: Aggregator
    ](self, name: String, start: Int, end: Int, width: Int) raises -> List[
        Bucket
    ]:
        validate_name(name)
        validate_range(start, end)
        if width <= 0:
            raise Error("bucket width must be positive")
        if name not in self.index:
            return List[Bucket]()
        return self.series[self.index[name]].downsample[A](start, end, width)

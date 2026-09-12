"""Run with `zig build example`."""

from aggregations import Aggregator, Minimum, Maximum
from engine import Engine


struct Spread(Aggregator):
    """Temperature swing: highest reading minus lowest reading."""

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


def main() raises:
    var db = Engine()
    db.put("greenhouse.temperature", 0, 18)
    db.put("greenhouse.temperature", 10, 21)
    db.put("greenhouse.temperature", 20, 19)
    db.put("greenhouse.temperature", 30, 25)

    var result = db.aggregate[Spread]("greenhouse.temperature", 0, 40)
    print(String("Temperature swing: ", result.value, " degrees"))

    var buckets = db.downsample[Spread]("greenhouse.temperature", 0, 40, 20)
    for bucket in buckets:
        print(String("Bucket ", bucket.start, ": swing = ", bucket.value))
    # Engine knows nothing about Spread; the trait is the entire contract.

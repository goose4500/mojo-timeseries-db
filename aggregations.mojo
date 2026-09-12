"""Small concrete types sharing a compile-time capability: Aggregator."""


trait Aggregator(Defaultable, Deinitable):
    """A fresh accumulator; finish is called only after at least one add."""

    def add(mut self, value: Float64):
        ...

    def finish(self) -> Float64:
        ...


struct Sum(Aggregator):
    var total: Float64

    def __init__(out self):
        self.total = 0

    def add(mut self, value: Float64):
        self.total += value

    def finish(self) -> Float64:
        return self.total


struct Mean(Aggregator):
    var total: Float64
    var count: Int

    def __init__(out self):
        self.total = 0
        self.count = 0

    def add(mut self, value: Float64):
        self.total += value
        self.count += 1

    def finish(self) -> Float64:
        return self.total / Float64(self.count)


struct Minimum(Aggregator):
    var value: Float64
    var seen: Bool

    def __init__(out self):
        self.value = 0
        self.seen = False

    def add(mut self, value: Float64):
        if not self.seen or value < self.value:
            self.value = value
        self.seen = True

    def finish(self) -> Float64:
        return self.value


struct Maximum(Aggregator):
    var value: Float64
    var seen: Bool

    def __init__(out self):
        self.value = 0
        self.seen = False

    def add(mut self, value: Float64):
        if not self.seen or value > self.value:
            self.value = value
        self.seen = True

    def finish(self) -> Float64:
        return self.value


struct Count(Aggregator):
    var count: Int

    def __init__(out self):
        self.count = 0

    def add(mut self, value: Float64):
        self.count += 1

    def finish(self) -> Float64:
        return Float64(self.count)

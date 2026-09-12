"""Versioned append-only text journal. Single process only; no fsync guarantee."""

from std.os.path import exists
from engine import Engine, validate_point, MAX_TIME_BOUND


comptime HEADER = "MOJO_TSDB_V1\n"


@fieldwise_init
struct Record(Copyable, Movable):
    var name: String
    var timestamp: Int
    var value: Float64


def parse_timestamp(text: String) raises -> Int:
    """Strict decimal parsing, with overflow checked before arithmetic."""
    if text.byte_length() == 0:
        raise Error("expected a nonnegative integer")
    var result = 0
    for char in text.as_bytes():
        if char < 48 or char > 57:
            raise Error("expected a nonnegative decimal integer: " + text)
        var digit = Int(char) - 48
        if result > (MAX_TIME_BOUND - digit) // 10:
            raise Error("integer exceeds signed 64-bit range")
        result = result * 10 + digit
    return result


def parse_records(text: String) raises -> List[Record]:
    """TSV rows with a required final newline; validate before returning rows.
    """
    var records = List[Record]()
    if text.byte_length() == 0:
        return records^
    if not text.endswith("\n"):
        raise Error(
            "incomplete final record: expected newline (file not modified)"
        )
    var lines = text.split("\n")
    for i in range(len(lines) - 1):
        try:
            var fields = lines[i].split("\t")
            if len(fields) != 3:
                raise Error("expected series<TAB>timestamp<TAB>value")
            var name = String(fields[0])
            var timestamp = parse_timestamp(String(fields[1]))
            var value = Float64(String(fields[2]))
            validate_point(name, timestamp, value)
            records.append(Record(name, timestamp, value))
        except error:
            raise Error(String("record ", i + 1, ": ", error))
    return records^


def create_database(path: String) raises:
    """Never intentionally overwrite an existing file. No concurrent access."""
    if exists(path):
        raise Error("path already exists; refusing to overwrite: " + path)
    with open(path, "w") as file:
        file.write(HEADER)


struct Database(Movable):
    var engine: Engine
    var path: String

    def __init__(out self, path: String) raises:
        self.path = path
        self.engine = Engine()
        var content: String
        with open(path, "r") as file:
            content = file.read()
        if not content.startswith(HEADER):
            raise Error("not a Mojo TSDB v1 journal")
        var records = parse_records(
            String(content[byte = String(HEADER).byte_length() :])
        )
        for record in records:
            self.engine.put(record.name, record.timestamp, record.value)

    def put(mut self, name: String, timestamp: Int, value: Float64) raises:
        validate_point(name, timestamp, value)
        # Log first: reopening can recover a write even if the process exits
        # before updating its in-memory index. Close flushes userspace buffers,
        # but this is NOT fsync/power-loss durability or a transaction.
        with open(self.path, "a") as file:
            file.write(String(name, "\t", timestamp, "\t", value, "\n"))
        self.engine.put(name, timestamp, value)

    def import_tsv(mut self, path: String) raises -> Int:
        var content: String
        with open(path, "r") as file:
            content = file.read()
        # Bad input changes nothing. IO failure during writes can still leave
        # a committed prefix: batch import is deliberately not transactional.
        var records = parse_records(content)
        for record in records:
            self.put(record.name, record.timestamp, record.value)
        return len(records)

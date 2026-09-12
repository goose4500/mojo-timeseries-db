"""Black-box tests of the compiled Mojo executable; no Python database code."""

import math
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build" / "tsdb"


class DatabaseCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mojo-tsdb-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "database.tsdb"
        self.run_cli("init", self.path)

    def run_cli(self, *args, ok=True):
        result = subprocess.run(
            [str(BINARY), *map(str, args)], capture_output=True, text=True,
            timeout=15,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def rows(self, command, *args):
        output = self.run_cli(command, self.path, *args)
        return [line.split("\t") for line in output.splitlines()[1:]]

    def test_reopen_ordering_and_last_write_wins(self):
        for timestamp, value in [(30, 3), (10, 1), (20, 2), (20, 8)]:
            self.run_cli("put", self.path, "cpu", timestamp, value)
        self.run_cli("put", self.path, "ram", 20, 99)
        self.assertEqual(self.rows("range", "cpu", 10, 30), [["10", "1.0"], ["20", "8.0"]])
        self.assertEqual(self.rows("series"), [["cpu", "3"], ["ram", "1"]])
        self.assertEqual(len(self.path.read_text().splitlines()), 6)

    def test_aggregations_and_buckets(self):
        for timestamp, value in [(5, 2), (14, 4), (15, 10), (35, 20), (40, 100)]:
            self.run_cli("put", self.path, "cpu", timestamp, value)
        for op, expected in [("sum", 36), ("mean", 9), ("min", 2), ("max", 20), ("count", 4)]:
            rows = self.rows("aggregate", "cpu", 5, 40, op)
            self.assertEqual(rows[0][0], "4")
            self.assertEqual(float(rows[0][1]), expected)
        self.assertEqual(self.rows("downsample", "cpu", 5, 40, 10, "mean"), [
            ["5", "2", "3.0"], ["15", "1", "10.0"], ["35", "1", "20.0"],
        ])

    def test_empty_results(self):
        self.assertEqual(self.rows("range", "missing", 0, 100), [])
        self.assertEqual(self.rows("downsample", "missing", 0, 100, 10, "mean"), [])
        for op in ["sum", "mean", "min", "max", "count"]:
            self.assertEqual(self.rows("aggregate", "missing", 0, 100, op), [["0", "null"]])
        self.assertEqual(self.rows("series"), [])

    def test_invalid_writes_do_not_change_journal(self):
        before = self.path.read_bytes()
        cases = [
            ("bad name", "0", "1"), ("bad\nname", "0", "1"),
            ("", "0", "1"), ("a" * 129, "0", "1"), ("café", "0", "1"),
            ("cpu", "-1", "1"), ("cpu", "9223372036854775808", "1"),
            ("cpu", "1.5", "1"), ("cpu", "0", "nan"), ("cpu", "0", "inf"),
            ("cpu", "0", "-inf"), ("cpu", "0", "1e999"),
            ("cpu", "0", "garbage"), ("cpu", "0", "1oops"),
        ]
        for args in cases:
            with self.subTest(args=args):
                self.run_cli("put", self.path, *args, ok=False)
                self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_queries_and_arguments(self):
        for args in [
            ("range", self.path, "cpu", 20, 10),
            ("range", self.path, "cpu", -1, 10),
            ("downsample", self.path, "cpu", 0, 10, 0, "sum"),
            ("downsample", self.path, "cpu", 0, 10, -1, "sum"),
            ("aggregate", self.path, "cpu", 0, 10, "median"),
            ("unknown", self.path), ("put", self.path),
            ("init", self.path, "extra"), ("series", self.path, "extra"),
        ]:
            with self.subTest(args=args):
                self.run_cli(*args, ok=False)
        self.assertIn("Ranges are", self.run_cli("--help"))

    def test_init_refuses_to_overwrite_and_missing_is_not_created(self):
        self.run_cli("put", self.path, "cpu", 0, 7)
        before = self.path.read_bytes()
        self.run_cli("init", self.path, ok=False)
        self.assertEqual(self.path.read_bytes(), before)
        missing = self.path.parent / "missing.tsdb"
        self.run_cli("put", missing, "cpu", 0, 7, ok=False)
        self.assertFalse(missing.exists())

    def test_import_and_input_validation_before_writing(self):
        source = self.path.parent / "input.tsv"
        source.write_text("cpu\t30\t3\ncpu\t10\t1\ncpu\t30\t9\nram\t10\t5\n")
        self.assertIn("imported 4", self.run_cli("import", self.path, source))
        self.assertEqual(self.rows("range", "cpu", 0, 40), [["10", "1.0"], ["30", "9.0"]])
        before = self.path.read_bytes()
        for text in ["cpu\t40\t4\nbroken\n", "cpu\t40\t4", "cpu\t40\t4\n\n"]:
            source.write_text(text)
            self.run_cli("import", self.path, source, ok=False)
            self.assertEqual(self.path.read_bytes(), before)
        source.write_text("")
        self.assertIn("imported 0", self.run_cli("import", self.path, source))

    def test_corruption_is_rejected_without_modifying_file(self):
        for data in [
            b"", b"not a database\n", b"MOJO_TSDB_V2\n",
            b"MOJO_TSDB_V1\ncpu\t1\t2",  # Torn final append.
            b"MOJO_TSDB_V1\ncpu\t1\t2\nbad\n",
            b"MOJO_TSDB_V1\ncpu\t1\tnan\n",
        ]:
            with self.subTest(data=data):
                self.path.write_bytes(data)
                self.run_cli("range", self.path, "cpu", 0, 10, ok=False)
                self.run_cli("put", self.path, "cpu", 2, 3, ok=False)
                self.assertEqual(self.path.read_bytes(), data)

    def test_float64_roundtrip_preserves_bits(self):
        values = [0.0, -0.0, 1.2345678901234567, 5e-324, 1.7976931348623157e308]
        randomizer = random.Random(42)
        while len(values) < 100:
            value = struct.unpack("!d", randomizer.getrandbits(64).to_bytes(8, "big"))[0]
            if math.isfinite(value):
                values.append(value)
        source = self.path.parent / "floats.tsv"
        source.write_text("".join(f"float\t{i}\t{value!r}\n" for i, value in enumerate(values)))
        self.run_cli("import", self.path, source)
        rows = self.rows("range", "float", 0, len(values))
        self.assertEqual(len(rows), len(values))
        for (_, text), expected in zip(rows, values):
            self.assertEqual(struct.pack("!d", float(text)), struct.pack("!d", expected))

    def test_timestamp_limits_and_wide_buckets(self):
        limit = 2**63 - 1
        self.run_cli("put", self.path, "cpu", limit - 1, 7)
        self.run_cli("put", self.path, "cpu", limit, 8, ok=False)
        self.assertEqual(self.rows("range", "cpu", limit - 1, limit), [[str(limit - 1), "7.0"]])
        self.assertEqual(self.rows("downsample", "cpu", limit - 5, limit, 10, "sum"), [
            [str(limit - 5), "1", "7.0"],
        ])
        self.assertEqual(self.rows("downsample", "cpu", 0, limit, limit, "sum"), [["0", "1", "7.0"]])
        self.assertEqual(self.rows("series"), [["cpu", "1"]])

    def test_replay_matches_reference_after_many_upserts(self):
        randomizer = random.Random(17)
        reference = {}
        source = self.path.parent / "random.tsv"
        lines = []
        for _ in range(500):
            timestamp, value = randomizer.randrange(100), randomizer.randrange(-1000, 1000)
            reference[timestamp] = value
            lines.append(f"sensor\t{timestamp}\t{value}\n")
        source.write_text("".join(lines))
        self.run_cli("import", self.path, source)
        for start, end in [(0, 100), (0, 0), (17, 42), (99, 100), (100, 200)]:
            expected = sorted((t, v) for t, v in reference.items() if start <= t < end)
            actual = [(int(t), float(v)) for t, v in self.rows("range", "sensor", start, end)]
            self.assertEqual(actual, expected)

    def test_trait_contract_is_checked_by_compiler(self):
        source = self.path.parent / "broken.mojo"
        source.write_text(
            "from aggregations import Aggregator\n"
            "struct Broken(Aggregator):\n"
            "    def __init__(out self):\n        pass\n"
            "    def add(mut self, value: Float64):\n        pass\n"
            "def main():\n    pass\n"
        )
        result = subprocess.run(
            ["mojo", "build", "-I", str(ROOT), str(source), "-o", str(self.path.parent / "broken")],
            text=True, capture_output=True, timeout=120,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not implement all requirements", result.stderr)
        self.assertIn("finish", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

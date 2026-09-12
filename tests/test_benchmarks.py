"""Smoke-test the native benchmark harness without asserting timing thresholds."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("TSDB_BENCHMARK_BINARY", ROOT / "zig-out" / "bin" / "benchmarks"))


class Benchmarks(unittest.TestCase):
    def test_all_workloads_and_partial_bucket(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.tsdb"
            result = subprocess.run(
                [str(BINARY), str(path), "101"], text=True,
                capture_output=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("Benchmark Report"), 5)
            for name in ["Replay", "Ordered insertion", "Reverse-order insertion",
                         "In-memory aggregation", "Downsampling"]:
                self.assertIn(name, result.stdout)
            self.assertEqual(len(path.read_text().splitlines()), 102)

    def test_invalid_size_does_not_create_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.tsdb"
            for size in ["0", "1000001", "-1", "invalid"]:
                result = subprocess.run(
                    [str(BINARY), str(path), size], capture_output=True, timeout=15,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(path.exists())

    def test_existing_file_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing.tsdb"
            path.write_bytes(b"preserve this data\n")
            result = subprocess.run(
                [str(BINARY), str(path), "10"], capture_output=True, timeout=15,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), b"preserve this data\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Run native benchmarks with a disposable journal and record host context."""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--points", type=int, default=10_000)
    args = parser.parse_args()
    if not 1 <= args.points <= 1_000_000:
        parser.error("--points must be between 1 and 1000000")
    print(f"Host: {platform.platform()}", flush=True)
    subprocess.run(["mojo", "--version"], check=True)
    subprocess.run(["mojo", "build", "--print-effective-target"], check=True)
    print("Build: -O3; warmup enabled; setup and process startup excluded.", flush=True)
    with tempfile.TemporaryDirectory(prefix="mojo-tsdb-bench-") as directory:
        subprocess.run(
            [os.environ.get("TSDB_BENCHMARK_BINARY", str(ROOT / "zig-out" / "bin" / "benchmarks")), str(Path(directory) / "fixture.tsdb"), str(args.points)],
            check=True,
        )


if __name__ == "__main__":
    main()

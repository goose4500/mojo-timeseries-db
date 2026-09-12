#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
db="$work/greenhouse.tsdb"
run() {
    printf '\n> tsdb'
    printf ' %q' "$@"
    printf '\n'
    ./build/tsdb "$@"
}
run init "$db"
run import "$db" examples/greenhouse.tsv
run series "$db"
run range "$db" greenhouse.temperature 0 60
run aggregate "$db" greenhouse.temperature 0 60 mean
run downsample "$db" greenhouse.temperature 0 60 20 mean
# A late reading and a correction: both survive reopening the database.
run put "$db" greenhouse.temperature 15 22
run put "$db" greenhouse.temperature 30 24
run range "$db" greenhouse.temperature 10 40

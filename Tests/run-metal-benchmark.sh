#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$test_dir/.." && pwd)"
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/dayu-metal-benchmark.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
mkdir -p "$project_dir/Analysis/Levelmatic"
xcrun clang++ -O3 -std=c++17 -fobjc-arc \
    -framework Foundation -framework Metal -framework Accelerate \
    "$test_dir/MetalDispatchBenchmark.mm" -o "$benchmark_dir/MetalDispatchBenchmark"
"$benchmark_dir/MetalDispatchBenchmark" "$project_dir/Analysis/Levelmatic/metal-benchmark.json"

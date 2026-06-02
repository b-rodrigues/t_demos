#!/usr/bin/env bash
set -e

# Change directory to the project directory to ensure paths are correct
cd "$(dirname "$0")"

echo "=== Initializing and building pipeline with sleep_time = 2 ==="
# Ensure sleep_time is set to 2
sed -i "s/sleep_time = .*/sleep_time = 2/" src/pipeline.t

# Build and export cache
nix develop --command t run --unsafe src/export.t

# Clear Nix store
echo "=== Running Nix Garbage Collector ==="
nix-store --gc

# Change sleep_time to 1
echo "=== Changing sleep_time to 1 in pipeline.t ==="
sed -i "s/sleep_time = .*/sleep_time = 1/" src/pipeline.t

# Measure Scenario A: Rebuild without cache import
echo "=== SCENARIO A: Rebuild WITHOUT cache import ==="
START_A=$(date +%s)
nix develop --command t run --unsafe src/build_only.t
END_A=$(date +%s)
DURATION_A=$((END_A - START_A))
echo "Scenario A took: ${DURATION_A} seconds"

# Clear Nix store again to ensure clean state
echo "=== Running Nix Garbage Collector ==="
nix-store --gc

# Measure Scenario B: Rebuild WITH cache import
echo "=== SCENARIO B: Rebuild WITH cache import ==="
START_B=$(date +%s)
nix develop --command t run --unsafe src/import.t
END_B=$(date +%s)
DURATION_B=$((END_B - START_B))
echo "Scenario B took: ${DURATION_B} seconds"

echo "======================================"
echo "Scenario A (no cache): ${DURATION_A} seconds"
echo "Scenario B (with cache): ${DURATION_B} seconds"
echo "======================================"

if [ "$DURATION_B" -lt "$DURATION_A" ]; then
  echo "SUCCESS: Cache import made the rebuild faster!"
else
  echo "WARNING: Cache import did not result in a faster build (Scenario A: $DURATION_A s, Scenario B: $DURATION_B s)"
fi

#!/usr/bin/env bash
set -e

# Change directory to the project directory to ensure paths are correct
cd "$(dirname "$0")"

echo "=== Initializing and building pipeline with sleep 20 ==="
# Ensure node2 sleeps for 20 seconds
sed -i 's/sleep [0-9]\+ && echo "Node 2"/sleep 20 \&\& echo "Node 2"/' src/pipeline_def.t

# Build and export cache
nix develop --command t run --failfast --unsafe src/export.t

# Clear Nix store
echo "=== Running Nix Garbage Collector ==="
nix-store --gc

# Change sleep time to 1 second
echo "=== Changing sleep time to 1 in pipeline_def.t ==="
sed -i 's/sleep [0-9]\+ && echo "Node 2"/sleep 1 \&\& echo "Node 2"/' src/pipeline_def.t

# Measure Scenario A: Rebuild without cache import
echo "=== SCENARIO A: Rebuild WITHOUT cache import ==="
START_A=$(date +%s)
nix develop --command t run --failfast --unsafe src/build_only.t
END_A=$(date +%s)
DURATION_A=$((END_A - START_A))
echo "Scenario A took: ${DURATION_A} seconds"

# Clear Nix store again to ensure clean state
echo "=== Running Nix Garbage Collector ==="
nix-store --gc

# Measure Scenario B: Rebuild WITH cache import
echo "=== SCENARIO B: Rebuild WITH cache import ==="
START_B=$(date +%s)
nix develop --command t run --failfast --unsafe src/import.t
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

echo ""
echo "=== SCENARIO C: Run Granular, Variadic, and Introspection Demo Test ==="
nix develop --command t run --failfast --unsafe src/granular_test.t
echo "SUCCESS: All scenarios completed successfully!"


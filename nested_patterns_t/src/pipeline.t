-- src/pipeline.t
-- Demonstrates chained pattern expansion across stages:
--   Stage 1: map_pattern(groups) → 2 base branches (50, 100)
--   Stage 2: cross_pattern(map_pattern(base), map_pattern(adjustments)) → 6 final branches
--
-- Expected values (stage 2 arithmetic):
--   (10*5) + 1 = 51    (10*5) + 2 = 52    (10*5) + 3 = 53
--   (20*5) + 1 = 101   (20*5) + 2 = 102   (20*5) + 3 = 103

import colcraft
import strcraft

p = pipeline {
  groups = [10, 20]
  adjustments = [1, 2, 3]

  -- Stage 1: expand groups via map_pattern (2 branches)
  base = node(
    command = <{ groups * 5 }>,
    pattern = map_pattern(groups)
  )

  -- Stage 2: cross expanded bases × adjustments (6 branches)
  -- map_pattern(base) resolves through Stage 1's expanded_map
  final = node(
    command = <{ base + adjustments }>,
    pattern = cross_pattern(map_pattern(base), map_pattern(adjustments))
  )
}

print("===============================================")
print("Nested Patterns Demo (Chained Expansion)")
print("===============================================")
print("groups = [10, 20] (2 values)")
print("adjustments = [1, 2, 3] (3 values)")
print("Stage 1: map_pattern(groups) → 2 base branches")
print("Stage 2: cross_pattern(base, adjustments) → 6 final branches")
print("")

print("")
-- Test lazy branch access before building

nodes = pipeline_nodes(p)
assert(length(nodes) == 12,
  str_join(["Expected 12 nodes (4 base + 2 base_branch + 6 final_branch), got ", length(nodes)], ""))
assert(str_detect(str_join(nodes, " "), "final_branch_1"),
  "pipeline_nodes should contain final_branch_1")
assert(str_detect(str_join(nodes, " "), "final_branch_6"),
  "pipeline_nodes should contain final_branch_6")

-- inspect_pipeline shows chained branches pre-build
pre_frame = inspect_pipeline(p)
assert(nrow(pre_frame) == 12,
  str_join(["inspect_pipeline should show 12 rows (4 base + 8 branches), got ", nrow(pre_frame)], ""))

print("")
-- 1. Expand and verify structure
p_expanded = expand_pipeline(p)
node_count = length(pipeline_nodes(p_expanded))
assert(node_count == 10, str_join(["Expected 10 nodes (2 roots + 2 base + 6 final), got ", node_count], ""))

frame = pipeline_to_frame(p_expanded)

-- Verify branch counts
base_branches = filter(frame, \(r) starts_with(r.name, "base_branch"))
final_branches = filter(frame, \(r) starts_with(r.name, "final_branch"))
assert(nrow(base_branches) == 2, str_join(["Expected 2 base branches, got ", nrow(base_branches)], ""))
assert(nrow(final_branches) == 6, str_join(["Expected 6 final branches, got ", nrow(final_branches)], ""))

-- Verify runtime propagation (all T, the default)
t_nodes = filter(frame, \(r) r.runtime == "T")
assert(nrow(t_nodes) == 10, str_join(["Expected 10 nodes with runtime=T, got ", nrow(t_nodes)], ""))

-- Verify edge count
edge_count = length(pipeline_edges(p_expanded))
-- 2 base→groups + 6 final→base + 6 final→adjustments = 14
assert(edge_count == 14, str_join(["Expected 14 edges after expansion, got ", edge_count], ""))

print(str_join(["✓ expanded structure: ", node_count, " nodes, 2 base, 6 final, ", edge_count, " edges, all T runtime"], ""))
print("")

-- 2. Build pipeline
res = build_pipeline(p)

if (is_error(res)) {
  print("Pipeline build failed:")
  print(res)
  assert(false, "Build should succeed")
}

assert(length(res.failed_nodes) == 0, "All nodes should build successfully")

-- 3. Verify leaf branch values (cross_pattern: (10*5)+[1,2,3], (20*5)+[1,2,3])
v1 = read_node(p.final_branch_1)
v2 = read_node(p.final_branch_2)
v3 = read_node(p.final_branch_3)
v4 = read_node(p.final_branch_4)
v5 = read_node(p.final_branch_5)
v6 = read_node(p.final_branch_6)

assert(v1 == 51, str_join(["Expected final_branch_1 = 51, got ", v1], ""))
assert(v2 == 52, str_join(["Expected final_branch_2 = 52, got ", v2], ""))
assert(v3 == 53, str_join(["Expected final_branch_3 = 53, got ", v3], ""))
assert(v4 == 101, str_join(["Expected final_branch_4 = 101, got ", v4], ""))
assert(v5 == 102, str_join(["Expected final_branch_5 = 102, got ", v5], ""))
assert(v6 == 103, str_join(["Expected final_branch_6 = 103, got ", v6], ""))
print("✓ all 6 final branch values correct (51..53, 101..103)")

print("")
print("✓ nested_patterns_t: all assertions passed")

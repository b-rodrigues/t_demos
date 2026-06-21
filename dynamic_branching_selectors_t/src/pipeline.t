-- Validates all four selector pattern types end-to-end:
-- slice_pattern, head_pattern, tail_pattern, sample_pattern.
-- Includes T, R, and Python branches with cross-runtime JSON interchange.

import colcraft

p = pipeline {
  nums = [10, 20, 30, 40, 50]

  --
  -- T nodes: exercise all 4 selector patterns
  --
  sliced = node(
    command = <{ nums * 2 }>,
    pattern = slice_pattern(nums, [0, 2, 4])
  )
  headed = node(
    command = <{ nums + 1 }>,
    pattern = head_pattern(nums, 3)
  )
  tailed = node(
    command = <{ nums + 100 }>,
    pattern = tail_pattern(nums, 2)
  )
  sampled = node(
    command = <{ nums }>,
    pattern = sample_pattern(nums, 2)
  )

  --
  -- R and Python: cross-runtime selector patterns with JSON interchange
  --
  r_tailed = node(
    command = <{ nums + 1 }>,
    pattern = tail_pattern(nums, 2),
    runtime = R,
    serializer = ^json,
    deserializer = ^json
  )
  py_headed = node(
    command = <{ nums * 10 }>,
    pattern = head_pattern(nums, 3),
    runtime = Python,
    serializer = ^json,
    deserializer = ^json
  )
}

print("===============================================")
print("Selector Patterns Demo")
print("===============================================")
print("nums = [10, 20, 30, 40, 50]")
print("slice_pattern(nums, [0, 2, 4]) → 3 branches (indices 0,2,4)")
print("head_pattern(nums, 3)        → 3 branches (first 3)")
print("tail_pattern(nums, 2)        → 2 branches (last 2)")
print("sample_pattern(nums, 2)      → 2 branches (random, deterministic)")
print("")
print("R:  tail_pattern(nums, 2)    → 2 branches, JSON interchange")
print("Py: head_pattern(nums, 3)    → 3 branches, JSON interchange")

-- Expand and verify structure
p_expanded = expand_pipeline(p)
node_count = length(pipeline_nodes(p_expanded))
assert(node_count == 16, str_join(["Expected 16 nodes (1 root + 3+3+2+2+2+3), got ", node_count], ""))

-- Branch counts per pattern
frame = pipeline_to_frame(p_expanded)
sliced_n  = nrow(filter(frame, \(r) starts_with(r.name, "sliced_branch")))
headed_n  = nrow(filter(frame, \(r) starts_with(r.name, "headed_branch")))
tailed_n  = nrow(filter(frame, \(r) starts_with(r.name, "tailed_branch")))
sampled_n = nrow(filter(frame, \(r) starts_with(r.name, "sampled_branch")))
r_tail_n  = nrow(filter(frame, \(r) starts_with(r.name, "r_tailed_branch")))
py_head_n = nrow(filter(frame, \(r) starts_with(r.name, "py_headed_branch")))

assert(sliced_n == 3,  str_join(["Expected 3 sliced branches, got ", sliced_n], ""))
assert(headed_n == 3,  str_join(["Expected 3 headed branches, got ", headed_n], ""))
assert(tailed_n == 2,  str_join(["Expected 2 tailed branches, got ", tailed_n], ""))
assert(sampled_n == 2, str_join(["Expected 2 sampled branches, got ", sampled_n], ""))
assert(r_tail_n == 2,  str_join(["Expected 2 r_tailed branches, got ", r_tail_n], ""))
assert(py_head_n == 3, str_join(["Expected 3 py_headed branches, got ", py_head_n], ""))

-- Verify runtime propagation
r_branches = filter(frame, \(r) r.runtime == "R")
py_branches = filter(frame, \(r) r.runtime == "Python")
assert(nrow(r_branches) == 2,  str_join(["Expected 2 R runtime branches, got ", nrow(r_branches)], ""))
assert(nrow(py_branches) == 3, str_join(["Expected 3 Python runtime branches, got ", nrow(py_branches)], ""))

print("✓ expanded structure correct: 16 nodes, 6 pattern groups, runtimes OK")

-- Build and verify
res = build_pipeline(p)

if (is_error(res)) {
  print("Pipeline build failed:")
  print(res)
  assert(false, "Build should succeed")
}

log_frame = build_log_to_frame(res)
assert(nrow(log_frame) == 16, str_join(["Expected 16 built nodes, got ", nrow(log_frame)], ""))
assert(length(res.failed_nodes) == 0, "All nodes should build successfully")

print("✓ dynamic_branching_selectors_t: all assertions passed")

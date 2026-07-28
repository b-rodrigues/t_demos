-- src/pipeline.t
-- Demonstrates graceful degradation when one branch of a map_pattern fails.
--
-- nums = [10, 20, 30] → 3 R branches via map_pattern
-- Branch receiving 20 triggers stop("intentional branch failure")
-- Other two branches succeed (val * 2 → 20, 60)

import colcraft

p = pipeline {
  nums = [10, 20, 30]

  results = node(
    command = <{
      val <- nums[[1]]
      if (val == 20) stop("intentional branch failure")
      val * 2
    }>,
    pattern = map_pattern(nums),
    runtime = R,
    serializer = ^json,
    deserializer = ^json
  )
}

-- Set JSON serializer on nums so R nodes can deserialize
p := set(p, node_meta_lens("nums", "serializer"), ^json)

print("===============================================")
print("Branch Failure Recovery Demo")
print("===============================================")
print("nums = [10, 20, 30]")
print("map_pattern(nums) → 3 branches (R runtime)")
print("Branch 2 (val=20) triggers stop() → intentional failure")
print("Branches 1 and 3 should succeed (val*2 → 20, 60)")
print("")

-- Expand and verify structure first
p_expanded = expand_pipeline(p)
node_count = length(pipeline_nodes(p_expanded))
assert(node_count == 4, str_join(["Expected 4 nodes (1 root + 3 branches), got ", node_count], ""))

-- Branch naming convention
frame = pipeline_to_frame(p_expanded)
branch_nodes = filter(frame, \(r) starts_with(r.name, "results_branch"))
assert(nrow(branch_nodes) == 3, str_join(["Expected 3 results branches, got ", nrow(branch_nodes)], ""))

-- Verify runtime propagation
r_branches = filter(frame, \(r) r.runtime == "R")
assert(nrow(r_branches) == 3, str_join(["Expected 3 R runtime branches, got ", nrow(r_branches)], ""))

print("✓ expanded structure correct: 4 nodes, 3 R branches")
print("")

-- Build pipeline (uses expanded form internally)
build_pipeline(p, verbose = 1)

-- Retrieve build log from expanded pipeline
bl = build_log(p_expanded)
log_frame = build_log_to_frame(bl)

-- Build log should show all entries including the failed branch
assert(nrow(log_frame) == 4, str_join(["Expected 4 log entries, got ", nrow(log_frame)], ""))
print("✓ build_log_to_frame: 4 entries")

-- Filter to failed branches in the log
failed_branches = filter(log_frame, \(r) starts_with(r.name, "results_branch") && r.status == "Completed with error")
assert(nrow(failed_branches) == 1, str_join(["Expected 1 failed branch, got ", nrow(failed_branches)], ""))

-- Verify the error message is informative from the node directly
error_message = error_msg(p.results_branch_2)
print(str_join(["Error message: ", error_message], ""))

assert(str_detect(error_message, "intentional branch failure"),
  str_join(["Expected error message to mention cause, got: ", error_message], ""))
print("✓ error diagnostics: 1 failed branch, informative message")

-- Successful branches should be readable
branch1 = read_node(p.results_branch_1)
assert(branch1 == 20, str_join(["Expected branch 1 to be 20, got ", branch1], ""))

print("")
print("✓ branch_failure_t: all assertions passed")

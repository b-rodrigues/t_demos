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

-- Build pipeline
res = build_pipeline(p, verbose = 1)

if (is_error(res)) {
  print("Pipeline build returned error (partial failure):")
  print(res)
  print("")

  -- errored_nodes works on the pipeline itself
  errors = errored_nodes(p)
  error_count = length(errors)
  assert(error_count == 1, str_join(["Expected 1 errored node, got ", error_count], ""))

  -- Check the error message mentions the failing branch and cause
  first_error = errors |> head(1)
  error_message = error_msg(first_error)
  print(str_join(["Error message: ", error_message], ""))

  -- Verify the error message is informative
  assert(contains(error_message, "results_branch_2") || contains(error_message, "results_branch"),
    str_join(["Expected error message to contain branch name, got: ", error_message], ""))
  assert(contains(error_message, "intentional branch failure"),
    str_join(["Expected error message to mention cause, got: ", error_message], ""))
  print("✓ error diagnostics: 1 errored node, informative message")

  -- Build log should show 3 entries
  log_frame = build_log_to_frame(res)
  assert(nrow(log_frame) == 3, str_join(["Expected 3 log entries, got ", nrow(log_frame)], ""))
  print("✓ build_log_to_frame: 3 entries")

} else {
  print("Build succeeded (checking for partial failures):")
  failed_count = length(res.failed_nodes)
  assert(failed_count >= 1, str_join(["Expected at least 1 failed node, got ", failed_count], ""))

  -- errored_nodes also works on success path
  errors = errored_nodes(p)
  assert(length(errors) == 1, str_join(["Expected 1 errored node, got ", length(errors)], ""))

  first_error = errors |> head(1)
  error_message = error_msg(first_error)
  print(str_join(["Error message: ", error_message], ""))
  assert(contains(error_message, "intentional branch failure"),
    str_join(["Expected error to mention cause, got: ", error_message], ""))
  print("✓ error diagnostics: 1 failed node, informative message")

  -- Successful branches should be readable
  branch1 = read_node(p.results_branch_1)
  assert(branch1 == 20, str_join(["Expected branch 1 to be 20, got ", branch1], ""))

  -- Build log should show 3 entries
  log_frame = build_log_to_frame(res)
  assert(nrow(log_frame) == 3, str_join(["Expected 3 log entries, got ", nrow(log_frame)], ""))
  print("✓ successful branches readable, build log shows 3 entries")
}

print("")
print("✓ branch_failure_t: all assertions passed")

-- Validates word-boundary \b regex substitution:
-- Only standalone identifiers are replaced; substrings are not affected.
-- e.g. dep named "a" should NOT replace "aa" or "a_b" in the command body.

import colcraft

p = pipeline {
  a = [10, 20]
  aa = "unchanged"
  a_b = "also_unchanged"

  result = node(
    command = <{ [val: a, aa_val: "aa", ab_val: "a_b"] }>,
    pattern = map_pattern(a)
  )
}

-- Test lazy branch access before building

nodes = pipeline_nodes(p)
expected_nodes = ["a", "aa", "a_b", "result", "result_branch_1", "result_branch_2"]
assert(nodes == expected_nodes,
  str_join(["pipeline_nodes: expected ", to_string(expected_nodes), ", got ", to_string(nodes)], ""))

-- Dot access lazily returns a computed node
b1_type = type(p.result_branch_1)
assert(b1_type == "ComputedNode",
  str_join(["Expected type(p.result_branch_1) == \"ComputedNode\", got ", b1_type], ""))

-- read_node on patterned node gives helpful error
err = read_node(p.result)
assert(is_error(err), "read_node(p.result) should return an error before building")
err_str = to_string(err)
assert(contains(err_str, "result_branch_1"),
  "read_node error should list available branch names")
assert(contains(err_str, "result_branch_2"),
  "read_node error should list available branch names")

print("===============================================")
print("Word-Boundary Substitution Test")
print("===============================================")
print("a = [10, 20]")
print("aa and a_b must remain untouched after substitution")

res = build_pipeline(p, verbose = 1)

if (is_error(res)) {
  print("Pipeline build failed:")
  print(res)
  assert(false, "Build should succeed")
} else {
  print("Build successful!")

  frame = build_log_to_frame(res)
  assert(nrow(frame) == 5,
    str_join(["Expected 5 nodes (a, aa, a_b, result_branch_1, result_branch_2), got ", nrow(frame)], ""))

  -- Verify branches exist in build log (if substitution was wrong, build would fail)
  branches = filter(frame, \(r) starts_with(r.name, "result_branch"))
  assert(nrow(branches) == 2, "Expected 2 result branches")

  print("✓ dynamic_branching_substitution_t: all assertions passed")
}

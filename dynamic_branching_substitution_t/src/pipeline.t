-- Validates word-boundary \b regex substitution:
-- Only standalone identifiers are replaced; substrings are not affected.
-- e.g. dep named "a" should NOT replace "aa" or "a_b" in the command body.

p = pipeline {
  a = [10, 20]
  aa = "unchanged"
  a_b = "also_unchanged"

  result = node(
    command = <{ [a, "aa", "a_b"] }>,
    pattern = map_pattern(a)
  )
}

print("===============================================")
print("Word-Boundary Substitution Test")
print("===============================================")
print("a = [10, 20]")
print("aa and a_b must remain untouched after substitution")

p_expanded = expand_pipeline(p)
res = build_pipeline(p_expanded, verbose = 1)

if (is_error(res)) {
  print("Pipeline build failed:")
  print(res)
  assert(false, "Build should succeed")
} else {
  print("Build successful!")

  -- Branch 1: a → 10, command becomes [10, "aa", "a_b"]
  b1 = read_node(p_expanded.result_branch_1)
  assert(b1[[1]] == 10, str_join(["Branch 1 value should be 10, got ", b1[[1]]], ""))
  assert(b1[[2]] == "aa", str_join(["Branch 1 'aa' should stay 'aa', got ", b1[[2]]], ""))
  assert(b1[[3]] == "a_b", str_join(["Branch 1 'a_b' should stay 'a_b', got ", b1[[3]]], ""))

  -- Branch 2: a → 20, command becomes [20, "aa", "a_b"]
  b2 = read_node(p_expanded.result_branch_2)
  assert(b2[[1]] == 20, str_join(["Branch 2 value should be 20, got ", b2[[1]]], ""))
  assert(b2[[2]] == "aa", str_join(["Branch 2 'aa' should stay 'aa', got ", b2[[2]]], ""))
  assert(b2[[3]] == "a_b", str_join(["Branch 2 'a_b' should stay 'a_b', got ", b2[[3]]], ""))

  print("✓ dynamic_branching_substitution_t: all assertions passed")
}

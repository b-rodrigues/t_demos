-- Validates word-boundary \b regex substitution:
-- Only standalone identifiers are replaced; substrings are not affected.
-- e.g. dep named "a" should NOT replace "aa" or "a_b" in the command body.

p = pipeline {
  a = [10, 20]
  aa = "unchanged"
  a_b = "also_unchanged"

  result = node(
    command = <{ [val: a, aa_val: "aa", ab_val: "a_b"] }>,
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

  -- Branch 1: a → 10, command becomes [val: 10, aa_val: "aa", ab_val: "a_b"]
  b1 = read_node(p_expanded.result_branch_1)
  assert(b1.val == 10, str_join(["Branch 1 value should be 10, got ", b1.val], ""))
  assert(b1.aa_val == "aa", str_join(["Branch 1 'aa' should stay 'aa', got ", b1.aa_val], ""))
  assert(b1.ab_val == "a_b", str_join(["Branch 1 'a_b' should stay 'a_b', got ", b1.ab_val], ""))

  -- Branch 2: a → 20, command becomes [val: 20, aa_val: "aa", ab_val: "a_b"]
  b2 = read_node(p_expanded.result_branch_2)
  assert(b2.val == 20, str_join(["Branch 2 value should be 20, got ", b2.val], ""))
  assert(b2.aa_val == "aa", str_join(["Branch 2 'aa' should stay 'aa', got ", b2.aa_val], ""))
  assert(b2.ab_val == "a_b", str_join(["Branch 2 'a_b' should stay 'a_b', got ", b2.ab_val], ""))

  print("✓ dynamic_branching_substitution_t: all assertions passed")
}

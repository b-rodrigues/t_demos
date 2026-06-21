-- Validates auto-expansion of patterned pipelines when used with
-- composition builtins (chain, parallel).

import colcraft

p = pipeline {
  a = [1, 2]
  b = node(command = <{ a + 10 }>, pattern = map_pattern(a))
}

q = pipeline { d = 100 }

print("===============================================")
print("Composition + Pattern Expansion Test")
print("===============================================")

-- chain a patterned pipeline with a non-patterned one
p_chain = chain(p, q)
res_chain = build_pipeline(p_chain, verbose = 1)
if (is_error(res_chain)) {
  assert(false, "chain on patterned pipeline should not error")
}

frame = build_log_to_frame(res_chain)
assert(nrow(frame) == 4, str_join(["Expected 4 nodes (a, b_branch_1, b_branch_2, d), got ", nrow(frame)], ""))
print("✓ chain: ", nrow(frame), " nodes built")

-- parallel a patterned pipeline with a non-patterned one
p_par = parallel(p, q)
res_par = build_pipeline(p_par, verbose = 1)
if (is_error(res_par)) {
  assert(false, "parallel on patterned pipeline should not error")
}

frame2 = build_log_to_frame(res_par)
assert(nrow(frame2) == 4, str_join(["Expected 4 nodes, got ", nrow(frame2)], ""))
print("✓ parallel: ", nrow(frame2), " nodes built")

print("✓ dynamic_branching_composition_t: all assertions passed")

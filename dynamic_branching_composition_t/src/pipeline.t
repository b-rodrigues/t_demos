-- Validates auto-expansion of patterned pipelines when used with
-- composition builtins (chain, parallel).

p = pipeline {
  a = [1, 2]
  b = node(command = <{ a + 10 }>, pattern = map_pattern(a))
}

build_pipeline(p)

q = pipeline { d = 100 }

print("===============================================")
print("Composition + Pattern Expansion Test")
print("===============================================")

-- parallel: auto-expand patterned pipeline + non-patterned one
p_par = parallel(p, q)
res_par = build_pipeline(p_par, verbose = 1)

if (is_error(res_par)) {
  assert(false, "parallel on patterned pipeline should not error")
}

frame = build_log_to_frame(res_par)
assert(nrow(frame) == 4, str_join(["Expected 4 nodes (a, b_branch_1, b_branch_2, d), got ", nrow(frame)], ""))
print("✓ parallel with patterned pipeline: ", nrow(frame), " nodes built")

print("✓ dynamic_branching_composition_t: all assertions passed")

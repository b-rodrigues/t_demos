-- src/pipeline.t
-- Demonstrates static conditionals: node_when and node_fork.
-- These functions are evaluated at pipeline construction time,
-- before any build starts. The condition determines which nodes
-- appear in the pipeline's static DAG.

print("")
print("== Static Conditionals Demo ==")
print("")

-- ============================================================
-- 1. node_when: conditionally include a node
-- ============================================================

print("--- 1. node_when ---")

-- node_when(true, node) includes the node
p1 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  heavy = node_when(true, node(command = "deep analysis", runtime = T))
}
build_pipeline(p1)
p1_check = length(pipeline_nodes(p1)) == 3
if (p1_check) {
  print("  ✓ node_when(true, node): 3 nodes (data, quick, heavy)")
} else {
  print(str_join(["  ✗ node_when(true, ...): expected 3 nodes, got ", length(pipeline_nodes(p1))], ""))
}
p1_val = read_node(p1.heavy)
if (p1_val == "deep analysis") {
  print("  ✓ node_when(true, ...): heavy == 'deep analysis'")
} else {
  print(str_join(["  ✗ node_when(true, ...): expected 'deep analysis', got ", p1_val], ""))
}

-- node_when(false, node) excludes the node
p2 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  heavy = node_when(false, node(command = "deep analysis", runtime = T))
}
build_pipeline(p2)
p2_check = length(pipeline_nodes(p2)) == 2
if (p2_check) {
  print("  ✓ node_when(false, node): 2 nodes, 'heavy' excluded")
} else {
  print(str_join(["  ✗ node_when(false, ...): expected 2 nodes, got ", length(pipeline_nodes(p2))], ""))
}
if (!contains(pipeline_nodes(p2), "heavy")) {
  print("  ✓ node_when(false, ...): 'heavy' correctly excluded from pipeline")
} else {
  print("  ✗ node_when(false, ...): 'heavy' should not be in pipeline")
}

-- Dynamic condition using an outer variable
include_extra = false
p3 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  extra = node_when(include_extra, node(command = "extra analysis", runtime = T))
}
build_pipeline(p3)
p3_check = length(pipeline_nodes(p3)) == 2
if (p3_check) {
  print("  ✓ node_when(include_extra=false, node): 2 nodes, 'extra' excluded")
} else {
  print(str_join(["  ✗ node_when(include_extra=false, ...): expected 2 nodes, got ", length(pipeline_nodes(p3))], ""))
}

-- Include extra (toggle include_extra = true above to include it)
print(str_join(["    (set include_extra = true to include 'extra' node)"], ""))

print("")

-- ============================================================
-- 2. node_fork: select between alternatives
-- ============================================================

print("--- 2. node_fork ---")

env_mode = "production"

p4 = pipeline {
  cfg = node_fork(
    env_mode == "development", node(command = "dev", runtime = T),
    env_mode == "staging",     node(command = "stg", runtime = T),
    env_mode == "production",  node(command = "prd", runtime = T),
    .default = node(command = "fallback", runtime = T)
  )
}
build_pipeline(p4)
p4_cfg = read_node(p4.cfg)
if (p4_cfg == "prd") {
  print("  ✓ node_fork(mode=production): cfg == 'prd'")
} else {
  print(str_join(["  ✗ node_fork(mode=production): expected 'prd', got ", p4_cfg], ""))
}

-- No matching condition, .default kicks in
env_mode2 = "testing"

p5 = pipeline {
  cfg = node_fork(
    env_mode2 == "development", node(command = "dev", runtime = T),
    env_mode2 == "production",  node(command = "prd", runtime = T),
    .default = node(command = "default_mode", runtime = T)
  )
}
build_pipeline(p5)
p5_cfg = read_node(p5.cfg)
if (p5_cfg == "default_mode") {
  print("  ✓ node_fork(no match, .default): cfg == 'default_mode'")
} else {
  print(str_join(["  ✗ node_fork(no match, .default): expected 'default_mode', got ", p5_cfg], ""))
}

-- No match and no .default — node is excluded entirely
p6 = pipeline {
  cfg = node_fork(false, node(command = "never", runtime = T))
}
build_pipeline(p6)
p6_check = length(pipeline_nodes(p6)) == 0
if (p6_check) {
  print("  ✓ node_fork(no match, no .default): 0 nodes (cfg excluded)")
} else {
  print(str_join(["  ✗ node_fork(no match, no .default): expected 0 nodes, got ", length(pipeline_nodes(p6))], ""))
}

-- .default works position-independently
p7 = pipeline {
  cfg = node_fork(.default = node(command = "fallback_val", runtime = T), false, node(command = "a", runtime = T), false, node(command = "b", runtime = T))
}
build_pipeline(p7)
p7_cfg = read_node(p7.cfg)
if (p7_cfg == "fallback_val") {
  print("  ✓ node_fork(.default first, no match): cfg == 'fallback_val'")
} else {
  print(str_join(["  ✗ node_fork(.default first, no match): expected 'fallback_val', got ", p7_cfg], ""))
}

-- Verify that p5-fork had 1 node
p5_len = length(pipeline_nodes(p5))
p6_len = length(pipeline_nodes(p6))
if (p5_len == 1 && p6_len == 0) {
  print("  ✓ node_fork: .default present -> 1 node; no .default -> 0 nodes")
}

print("")

-- ============================================================
-- 3. node_when with R and Python nodes
-- ============================================================

print("--- 3. node_when with R and Python ---")

-- node_when(true, rn(...)) includes the R node
p_r1 = pipeline {
  data = [1, 2, 3, 4, 5]
  total = sum(data)
  r_out = node_when(true, rn(command = <{ list(lang = "R", val = 42L) }>, serializer = ^json))
}
build_pipeline(p_r1)
if (length(pipeline_nodes(p_r1)) == 3) {
  print("  ✓ node_when(true, rn(...)): 3 nodes (data, total, r_out)")
} else {
  print(str_join(["  ✗ node_when(true, rn(...)): expected 3 nodes, got ", length(pipeline_nodes(p_r1))], ""))
}
p_r1_val = read_node(p_r1.r_out)
if (type(p_r1_val) == "Dict" && p_r1_val.lang == "R") {
  print("  ✓ node_when(true, rn(...)): r_out.lang == 'R'")
} else {
  print(str_join(["  ✗ node_when(true, rn(...)): expected Dict with lang='R', got ", p_r1_val], ""))
}

-- node_when(false, rn(...)) excludes the R node
p_r2 = pipeline {
  data = [1, 2, 3, 4, 5]
  total = sum(data)
  r_out = node_when(false, rn(command = <{ list(lang = "R", val = 42L) }>, serializer = ^json))
}
build_pipeline(p_r2)
if (length(pipeline_nodes(p_r2)) == 2) {
  print("  ✓ node_when(false, rn(...)): 2 nodes, 'r_out' excluded")
} else {
  print(str_join(["  ✗ node_when(false, rn(...)): expected 2 nodes, got ", length(pipeline_nodes(p_r2))], ""))
}
if (!contains(pipeline_nodes(p_r2), "r_out")) {
  print("  ✓ node_when(false, rn(...)): 'r_out' correctly excluded from pipeline")
} else {
  print("  ✗ node_when(false, rn(...)): 'r_out' should not be in pipeline")
}

-- node_when(true, pyn(...)) includes the Python node
p_py1 = pipeline {
  data = [1, 2, 3, 4, 5]
  total = sum(data)
  py_out = node_when(true, pyn(command = <{ {"lang": "py", "val": 42} }>, serializer = ^json))
}
build_pipeline(p_py1)
if (length(pipeline_nodes(p_py1)) == 3) {
  print("  ✓ node_when(true, pyn(...)): 3 nodes (data, total, py_out)")
} else {
  print(str_join(["  ✗ node_when(true, pyn(...)): expected 3 nodes, got ", length(pipeline_nodes(p_py1))], ""))
}
p_py1_val = read_node(p_py1.py_out)
if (type(p_py1_val) == "Dict" && p_py1_val.lang == "py") {
  print("  ✓ node_when(true, pyn(...)): py_out.lang == 'py'")
} else {
  print(str_join(["  ✗ node_when(true, pyn(...)): expected Dict with lang='py', got ", p_py1_val], ""))
}

-- node_when(false, pyn(...)) excludes the Python node
p_py2 = pipeline {
  data = [1, 2, 3, 4, 5]
  total = sum(data)
  py_out = node_when(false, pyn(command = <{ {"lang": "py", "val": 42} }>, serializer = ^json))
}
build_pipeline(p_py2)
if (length(pipeline_nodes(p_py2)) == 2) {
  print("  ✓ node_when(false, pyn(...)): 2 nodes, 'py_out' excluded")
} else {
  print(str_join(["  ✗ node_when(false, pyn(...)): expected 2 nodes, got ", length(pipeline_nodes(p_py2))], ""))
}
if (!contains(pipeline_nodes(p_py2), "py_out")) {
  print("  ✓ node_when(false, pyn(...)): 'py_out' correctly excluded from pipeline")
} else {
  print("  ✗ node_when(false, pyn(...)): 'py_out' should not be in pipeline")
}

print("")

-- ============================================================
-- 4. node_fork between R and Python nodes
-- ============================================================

print("--- 4. node_fork between R and Python ---")

model_lang = "python"
p_fork1 = pipeline {
  result = node_fork(
    model_lang == "R",      rn(command = <{ list(lang = "R") }>, serializer = ^json),
    model_lang == "python", pyn(command = <{ {"lang": "py"} }>, serializer = ^json),
    .default = node(command = "t_fallback", runtime = T)
  )
}
build_pipeline(p_fork1)
p_fork1_val = read_node(p_fork1.result)
if (type(p_fork1_val) == "Dict" && p_fork1_val.lang == "py") {
  print("  ✓ node_fork(model_lang=python): result.lang == 'py'")
} else {
  print(str_join(["  ✗ node_fork(model_lang=python): expected Dict with lang='py', got ", p_fork1_val], ""))
}

model_lang2 = "R"
p_fork2 = pipeline {
  result = node_fork(
    model_lang2 == "R",      rn(command = <{ list(lang = "R") }>, serializer = ^json),
    model_lang2 == "python", pyn(command = <{ {"lang": "py"} }>, serializer = ^json),
    .default = node(command = "t_fallback", runtime = T)
  )
}
build_pipeline(p_fork2)
p_fork2_val = read_node(p_fork2.result)
if (type(p_fork2_val) == "Dict" && p_fork2_val.lang == "R") {
  print("  ✓ node_fork(model_lang=R): result.lang == 'R'")
} else {
  print(str_join(["  ✗ node_fork(model_lang=R): expected Dict with lang='R', got ", p_fork2_val], ""))
}

-- No match, falls back to default T node
model_lang3 = "julia"
p_fork3 = pipeline {
  result = node_fork(
    model_lang3 == "R",      rn(command = <{ list(lang = "R") }>, serializer = ^json),
    model_lang3 == "python", pyn(command = <{ {"lang": "py"} }>, serializer = ^json),
    .default = node(command = "t_fallback", runtime = T)
  )
}
build_pipeline(p_fork3)
p_fork3_val = read_node(p_fork3.result)
if (p_fork3_val == "t_fallback") {
  print("  ✓ node_fork(no match, .default): result == 't_fallback'")
} else {
  print(str_join(["  ✗ node_fork(no match, .default): expected 't_fallback', got ", p_fork3_val], ""))
}

print("")

-- ============================================================
-- 5. Errors
-- ============================================================

print("--- 3. Errors ---")

-- Odd argument count: all conditions must be false to trigger
p8 = pipeline {
  x = node_fork(false, 1, false)
}
if (type(p8) == "Error") {
  print(str_join(["  ✓ odd arguments: ", error_msg(p8)], ""))
} else {
  print("  (no error — expected one)")
}

p9 = pipeline {
  x = node_fork(false, 1, .bad = 42)
}
if (type(p9) == "Error") {
  print(str_join(["  ✓ unexpected named arg: ", error_msg(p9)], ""))
} else {
  print("  (no error — expected one)")
}

print("")
print("== Done ==")

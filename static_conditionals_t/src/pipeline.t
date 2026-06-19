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

-- When the condition is true, the node is included
p1 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  heavy = node_when(true, "deep analysis")
}
print(str_join(["  node_when(true, ...)   => nodes: ", str_join(pipeline_nodes(p1), ", ")], ""))

-- When the condition is false, the node is excluded
p2 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  heavy = node_when(false, "deep analysis")
}
print(str_join(["  node_when(false, ...)  => nodes: ", str_join(pipeline_nodes(p2), ", ")], ""))

-- Dynamic condition: control inclusion via an env var
ci = env("CI")
p3 = pipeline {
  data = [1, 2, 3, 4, 5]
  quick = sum(data)
  heavy = node_when(ci == "1", "deep analysis")
}
ci_label = str_join(["CI = ", ci, " (set to 1 to include heavy)"])
print(str_join(["  ", ci_label, "  => nodes: ", str_join(pipeline_nodes(p3), ", ")], ""))

print("")

-- ============================================================
-- 2. node_fork: select between alternatives
-- ============================================================

print("--- 2. node_fork ---")

env_mode = "production"

p4 = pipeline {
  cfg = node_fork(
    env_mode == "development", "dev",
    env_mode == "staging",     "stg",
    env_mode == "production",  "prd",
    .default = "fallback"
  )
}
print(str_join(["  mode = \"production\"    => config node: ", get(pipeline_nodes(p4), 0)], ""))

-- No matching condition, .default kicks in
env_mode2 = "testing"

p5 = pipeline {
  cfg = node_fork(
    env_mode2 == "development", "dev",
    env_mode2 == "production",  "prd",
    .default = "default"
  )
}
print(str_join(["  mode = \"testing\" (no match, .default present)  => config node: ", get(pipeline_nodes(p5), 0)], ""))

-- No match and no .default — node is excluded entirely
p6 = pipeline {
  cfg = node_fork(false, "never")
}
print(str_join(["  no match, no default  => nodes: [", str_join(pipeline_nodes(p6), ", "), "]"], ""))

-- .default works position-independently
p7 = pipeline {
  cfg = node_fork(.default = "fallback", false, "a", false, "b")
}
print(str_join(["  .default first, no match => config node: ", get(pipeline_nodes(p7), 0)], ""))

print("")

-- ============================================================
-- 3. Errors
-- ============================================================

print("--- 3. Errors ---")

-- Odd argument count: all conditions must be false to trigger
p8 = pipeline {
  x = node_fork(false, 1, false)
}
if (type(p8) == "Error") {
  print(str_join(["  odd arguments: ", error_msg(p8)], ""))
} else {
  print("  (no error — expected one)")
}

p9 = pipeline {
  x = node_fork(false, 1, .bad = 42)
}
if (type(p9) == "Error") {
  print(str_join(["  unexpected named arg: ", error_msg(p9)], ""))
} else {
  print("  (no error — expected one)")
}

print("")
print("== Done ==")

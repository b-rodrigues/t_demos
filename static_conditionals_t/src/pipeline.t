-- src/pipeline.t
-- Demonstrates static conditionals for pipeline node construction.
-- node_when and node_fork are evaluated at pipeline construction time,
-- before any build starts. Tests check node presence/absence via
-- pipeline_nodes() — no read_node() needed.

ok = 0
ko = 0

print(str_join(["-- ", "static_conditionals_t", " --"], ""))

-- === node_when ===

-- node_when(true, ...) includes the node
p1 = pipeline { x = node_when(true, 42) }
nodes1 = pipeline_nodes(p1)
if (length(nodes1) == 1 && get(nodes1, 0) == "x") {
  ok := ok + 1
} else {
  print("  ✗ node_when(true, 42) should include node x")
  ko := ko + 1
}

-- node_when(false, ...) excludes the node
p2 = pipeline { x = node_when(false, 42) }
if (length(pipeline_nodes(p2)) == 0) {
  ok := ok + 1
} else {
  print("  ✗ node_when(false, 42) should exclude node x")
  ko := ko + 1
}

-- node_when with dynamic condition
ci = env("CI")
p3 = pipeline { x = node_when(ci == "1", "ci_mode") }
if (ci == "1") { len = 1 } else { len = 0 }
if (length(pipeline_nodes(p3)) == len) {
  ok := ok + 1
} else {
  print("  ✗ node_when with dynamic condition should match CI env var")
  ko := ko + 1
}

-- === node_fork ===

-- node_fork first condition truthy
p4 = pipeline { x = node_fork(true, 1, false, 2) }
nodes4 = pipeline_nodes(p4)
if (length(nodes4) == 1 && get(nodes4, 0) == "x") {
  ok := ok + 1
} else {
  print("  ✗ node_fork(true, 1, false, 2) should select first match")
  ko := ko + 1
}

-- node_fork second condition truthy
p5 = pipeline { x = node_fork(false, 1, true, 2) }
nodes5 = pipeline_nodes(p5)
if (length(nodes5) == 1 && get(nodes5, 0) == "x") {
  ok := ok + 1
} else {
  print("  ✗ node_fork(false, 1, true, 2) should select second match")
  ko := ko + 1
}

-- node_fork .default fallback
p6 = pipeline { x = node_fork(false, 1, false, 2, .default = 3) }
nodes6 = pipeline_nodes(p6)
if (length(nodes6) == 1 && get(nodes6, 0) == "x") {
  ok := ok + 1
} else {
  print("  ✗ node_fork with .default should fall back")
  ko := ko + 1
}

-- node_fork .default position independent
p7 = pipeline { x = node_fork(.default = 3, false, 1, false, 2) }
nodes7 = pipeline_nodes(p7)
if (length(nodes7) == 1 && get(nodes7, 0) == "x") {
  ok := ok + 1
} else {
  print("  ✗ node_fork .default should work position-independently")
  ko := ko + 1
}

-- node_fork no match no default — node excluded
p8 = pipeline { x = node_fork(false, 1) }
if (length(pipeline_nodes(p8)) == 0) {
  ok := ok + 1
} else {
  print("  ✗ node_fork(false, 1) no match no default should exclude node")
  ko := ko + 1
}

-- === node_fork error cases ===

-- node_fork odd arguments
p9 = pipeline { x = node_fork(false, 1, true) }
if (type(p9) == "Error" && str_detect(error_msg(p9), "expects an even number")) {
  ok := ok + 1
} else {
  print("  ✗ node_fork odd arguments should produce TypeError")
  ko := ko + 1
}

-- node_fork unexpected named argument
p10 = pipeline { x = node_fork(false, 1, .unexpected = 42) }
if (type(p10) == "Error" && str_detect(error_msg(p10), "unexpected named argument")) {
  ok := ok + 1
} else {
  print("  ✗ node_fork unexpected named argument should produce error")
  ko := ko + 1
}

-- === Combined usage ===

p11 = pipeline {
  data = [1, 2, 3, 4, 5]
  heavy = node_when(false, sum(data))
  light = sum(data)
}
nodes11 = pipeline_nodes(p11)
if (length(nodes11) == 2 && get(nodes11, 0) == "data" && get(nodes11, 1) == "light") {
  ok := ok + 1
} else {
  print("  ✗ combined pipeline: heavy excluded, only data and light present")
  ko := ko + 1
}

-- === Summary ===

total = str_join(["- Tests: ", to_string(ok + ko)], "")
print(str_join(["", total, ""], ""))
if (ko == 0) {
  print(str_join(["  ✓ All ", to_string(ok), " tests passed"], ""))
} else {
  print(str_join(["  ✗ ", to_string(ko), " of ", to_string(ok + ko), " tests failed"], ""))
}

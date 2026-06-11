import "src/pipeline_def.t"[p]

populate_pipeline(p, build = true, verbose = 1)

-- Node correctness assertions
assert(type(read_node(p.node1).error) == "NA", "node1 (shell) should succeed")
assert(type(read_node(p.node2).error) == "NA", "node2 (shell) should succeed")
assert(type(read_node(p.node3).error) == "NA", "node3 (shell) should succeed")

print("✓ artifact_transfer_t: all assertions passed")

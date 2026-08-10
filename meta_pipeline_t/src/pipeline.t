p_etl = pipeline {
  raw = 10
  clean = raw + 2
}

p_stats = pipeline {
  total = etl.clean * 3
}

meta = pipeline_of {
  etl = p_etl
  stats = p_stats
}

-- Ensure that meta has the correct nodes (implicitly flattened)
print("Nodes in meta:")
print(pipeline_nodes(meta))

-- Assert dependencies are correct (implicitly flattened)
deps = pipeline_deps(meta)
print("Deps in meta:")
print(deps)

-- Populate and build the meta-pipeline directly
populate_pipeline(meta, build = true, verbose = 1)
pipeline_copy()

-- Read the materialized node directly using nested dot-access!
print("Value of stats.total:")
val = read_node(meta.stats.total)
print(val)

-- Verify that the value is indeed (10 + 2) * 3 = 36
assert(val == 36, "Value should be 36")

-- Generate graph visualizations for the meta-pipeline
print("=== Meta-Pipeline DOT Visualization ===")
dot_str = pipeline_to_dot(meta)
print(dot_str)

print("=== Meta-Pipeline Mermaid Visualization ===")
mermaid_str = pipeline_to_mermaid(meta)
print(mermaid_str)

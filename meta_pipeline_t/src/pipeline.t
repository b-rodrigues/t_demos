p_etl = pipeline {
  raw = 10
  clean = raw + 2
}

p_stats = pipeline {
  summary = etl.clean * 3
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
print("Value of stats.summary:")
val = read_node(meta.stats.summary)
print(val)

-- Verify that the value is indeed (10 + 2) * 3 = 36
assert(val == 36, "Value should be 36")

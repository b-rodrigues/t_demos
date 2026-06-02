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

flat = meta_flatten(meta)

-- Ensure that flat has the correct nodes
print("Nodes in flat:")
print(pipeline_nodes(flat))

-- Assert dependencies are correct: stats.summary depends on etl.clean
deps = pipeline_deps(flat)
print("Deps in flat:")
print(deps)

populate_pipeline(flat, build = true, verbose = 1)
pipeline_copy()

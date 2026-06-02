-- A template lambda function returning a pipeline
make_stats_pipeline = \(multiplier: Int -> Pipeline) pipeline {
  raw = 10
  computed = raw * multiplier
}

-- Instantiate the pipeline with different parameter values
p1 = make_stats_pipeline(3)
p2 = make_stats_pipeline(5)

-- Inspect structures
print("Nodes in p1:")
print(pipeline_nodes(p1))
print("Nodes in p2:")
print(pipeline_nodes(p2))

-- Build and execute p1
populate_pipeline(p1, build = true, verbose = 1)
val1 = read_node(p1.computed)
print("p1.computed value:")
print(val1)
assert(val1 == 30, "p1.computed should be 30")

-- Build and execute p2
populate_pipeline(p2, build = true, verbose = 1)
val2 = read_node(p2.computed)
print("p2.computed value:")
print(val2)
assert(val2 == 50, "p2.computed should be 50")

print("All parameterized lambda pipeline checks passed!")

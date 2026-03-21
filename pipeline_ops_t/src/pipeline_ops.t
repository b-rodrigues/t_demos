-- src/pipeline_ops.t
-- Demonstrates advanced pipeline operations in T

-- 1. Create a base pipeline
base_p = pipeline {
  raw = node(
    command = read_csv("data/sample.csv"),
    serializer = "arrow"
  )
  
  -- Use node() with noop = true to skip heavy computation during builds
  heavy_r_node = rn(
    command = <{ 
      library(dplyr)
      raw %>% group_by(group) %>% summarize(total = sum(value))
    }>,
    deserializer = "arrow",
    serializer = "arrow",
    noop = true
  )

  -- This node depends on heavy_r_node, so it also becomes a noop
  summary = node(
    command = heavy_r_node |> filter($total > 100),
    deserializer = "arrow"
  )
}

-- 2. Introspection
print("Nodes in base_p:")
print(pipeline_nodes(base_p))

-- 3. Node Metadata as a DataFrame
df_meta = pipeline_to_frame(base_p)
print("Pipeline metadata:")
print(df_meta)

-- 4. Filtering and Selecting Nodes
-- Create a new pipeline with only R nodes
r_only = base_p |> filter_node($runtime == "R")
print("R nodes:")
print(pipeline_nodes(r_only))

-- 5. Mutating and Renaming
-- Rename 'raw' to 'source'
p_renamed = base_p |> rename_node("raw", "source")

-- 6. Set Operations
other_p = pipeline {
  extra_node = 42
  shared_node = 100
}

-- Union (parallel merges independent ones)
p_union = parallel(base_p, other_p)
print("Nodes in union (parallel):")
print(pipeline_nodes(p_union))

-- Patch
p_patch = base_p |> patch(pipeline { summary = 99 })
print("Patched summary node value in-memory:")
print(p_patch.summary)

-- 7. DAG-Aware Transformations
-- Subgraph of heavy_r_node
p_sub = base_p |> subgraph("heavy_r_node")
print("Subgraph of heavy_r_node:")
print(pipeline_nodes(p_sub))

-- Pruning leaves
p_pruned = base_p |> prune
print("Nodes after pruning:")
print(pipeline_nodes(p_pruned))

-- 8. Composition with chain
-- To demo 'chain', we define a multi-step composition. 
-- We use a single large pipeline then split it to show the wiring works.
p_full = pipeline {
  input_data = 10
  results = input_data * 2
}

p_step1 = p_full |> filter_node($name == "input_data")
p_step2 = p_full |> filter_node($name == "results")

print("Step 1 nodes: ")
print(pipeline_nodes(p_step1))
print("Step 2 nodes: ")
print(pipeline_nodes(p_step2))
print("Step 2 deps: ")
print(pipeline_deps(p_step2))

p_composed = p_step1 |> chain(p_step2)
print("Chained nodes (wiring verified):")
print(pipeline_nodes(p_composed))
print("Chained dependencies:")
print(pipeline_deps(p_composed))

-- 9. Validation
print("Validating base_p:")
print(pipeline_validate(base_p))

-- Triggering a build (would be noops for heavy nodes)
-- We use 'union' instead of 'chain' because the report does not have an explicit
-- T-visible dependency on nodes in 'base_p' to satisfy 'chain()'.
p_site = base_p |> union(pipeline {
  report = node(script = "src/report.qmd", runtime = Quarto)
})

populate_pipeline(p_site, build = true)
pipeline_copy()

print("Pipeline Demo Complete")

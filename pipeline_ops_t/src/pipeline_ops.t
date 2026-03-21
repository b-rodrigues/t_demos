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

print("Dependency graph:")
print(pipeline_deps(base_p))

-- 3. Node Metadata as a DataFrame
df_meta = pipeline_to_frame(base_p)
print("Pipeline metadata:")
print(df_meta)

-- 4. Filtering and Selecting Nodes
-- Create a new pipeline with only R nodes
r_only = base_p |> filter_node($runtime == "R")
print("R nodes:")
print(pipeline_nodes(r_only))

-- Select specific metadata
p_summary = base_p |> select_node($name, $runtime, $noop)
print("Selection summary:")
print(p_summary)

-- 5. Mutating and Renaming
-- Rename 'raw' to 'source'
p_renamed = base_p |> rename_node("raw", "source")

-- Mark all nodes as noop
p_all_noop = base_p |> mutate_node($noop = true)

-- 6. Set Operations
other_p = pipeline {
  extra_node = 42
  shared_node = 100
}

-- Union (fails on collision)
p_union = parallel(base_p, other_p) -- parallel merges independent ones
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
-- Create two pipelines to chain
-- We use node() to ensure the dependency 'input' is tracked accurately
p_start = pipeline { 
  shared_node = 10 
}

p_next = pipeline { 
  output = shared_node * 2
}

print("Nodes in p_next:")
print(pipeline_nodes(p_next))
print("Dependencies in p_next:")
print(pipeline_deps(p_next))

p_chained = p_start |> chain(p_next)
print("Chained nodes (wiring verified):")
print(pipeline_nodes(p_chained))
print("Chained dependencies:")
print(pipeline_deps(p_chained))

-- 9. Validation
print("Validating base_p:")
print(pipeline_validate(base_p))

-- Triggering a build (would be noops for heavy nodes)
p_site = base_p |> chain(pipeline {
  report = node(script = "src/report.qmd", runtime = Quarto)
})
populate_pipeline(p_site, build = true)
pipeline_copy()

print("Pipeline Demo Complete")

-- Demo: Pipeline manipulation and dynamic DAG generation.

-- 1. Create a base pipeline
base_p = pipeline {
  raw_data = node(command = dataframe(x = [1, 2], y = [3, 4]))
  process = node(command = raw_data |> mutate(z = x + y))
}

-- 2. Dynamically patch the pipeline
-- We'll rename a node and prune some leaves
modified_p = base_p
  |> rename_node("process", "final_result")
  |> mutate_node("final_result", noop: true)  -- Disable a node dynamically

-- 3. Extend the pipeline with a new node
extension = pipeline {
  extra_step = node(command = final_result |> mutate(msg = "extended"))
}
final_p = union(modified_p, extension)

-- 4. Build the dynamically generated pipeline
build_pipeline(final_p)

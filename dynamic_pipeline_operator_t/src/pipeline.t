import colcraft
import `pipeline`

-- 1. Create a base pipeline
base_p = pipeline {
  raw_data = node(command = dataframe([[x: 1, y: 3], [x: 2, y: 4]]))
  process = node(command = raw_data |> mutate(z = $x + $y))
}

-- 2. Dynamically patch the pipeline
-- We'll rename a node and prune some leaves
modified_p = base_p
  |> rename_node("process", "final_status")
  |> mutate_node("final_status", noop = false)  -- Keep the node enabled

-- 3. Extend the pipeline with a new node
-- Note: final_status is resolved when the pipelines are combined
extension = pipeline {
  extra_step = (final_status |> mutate(msg = "extended"))
}
final_p = union(modified_p, extension)

-- 4. Build the dynamically generated pipeline
build_pipeline(final_p)

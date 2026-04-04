-- 1. Create a base pipeline
base_p = pipeline {
  raw_data = node(command = dataframe([[x: 1, y: 3], [x: 2, y: 4]]))
  process = node(command = raw_data |> mutate(z = $x + $y))
}

-- 2. Dynamically patch the pipeline
-- We'll rename a node and prune some leaves
modified_p = base_p
  |> rename_node("process", "final_status")
  |> mutate_node("final_status", noop = false)

-- 3. Extend the pipeline with a new node.
-- Now that T supports lazy cross-pipeline dependency resolution, 
-- we can use direct references to "final_status" even if it's defined 
-- in another pipeline!
extension = pipeline {
  extra_step = (final_status |> mutate($msg = str_join([$z, " - extended"])))
}

-- 4. Combine them. Union now correctly resolves the "final_status" dependency 
-- by identifying it as a cross-pipeline reference. 
final_p = union(modified_p, extension)

-- 5. Build the dynamically generated pipeline
build_pipeline(final_p, verbose=1)

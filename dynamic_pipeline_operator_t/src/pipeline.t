-- ARCHITECTURAL NOTE:
-- This example currently uses the "Dependency Proxy" pattern (Step 3 & 4) to work 
-- around T's partially eager pipeline evaluation. 
--
-- EVOLUTION GOAL:
-- Once lazy cross-pipeline dependency resolution is implemented in the T engine,
-- Step 3 should simplify to a bare expression:
--   extension = pipeline { extra_step = (final_status |> mutate($msg = "extended")) }
-- And Step 4 should be a direct union without filtering:
--   final_p = union(modified_p, extension)
--
-- See tlang/spec_files/eager_pipeline_evaluation.md for full details.

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

-- 3. Extend the pipeline with a new node
-- We include a 'noop' proxy for final_status so the evaluator 
-- can wire the DAG without trying to execute the missing node.
extension = pipeline {
  final_status = node(noop = true)
  extra_step = node(
    command = <{ final_status |> mutate($msg = str_join(["Extended", ""])) }>,
    runtime = T
  )
}

-- 4. Combine them. We filter out our placeholder before the union.
-- T's filter_node removes the node from the list but preserves the 
-- dependency link in extra_step's metadata.
final_p = union(
  modified_p, 
  extension |> filter_node($name != "final_status")
)

-- 5. Build the dynamically generated pipeline
build_pipeline(final_p)

-- 1. Create a base pipeline
base_p = pipeline {
  raw_data = node(command = to_dataframe([[x: 1, y: 3], [x: 2, y: 4]]))
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

-- Verify all nodes succeeded in the dynamically composed pipeline
r_raw = read_node(final_p.raw_data)
assert(type(r_raw.error) == "NA", "raw_data should succeed")
assert(nrow(r_raw.value) == 2, "raw_data should have 2 rows")

r_final = read_node(final_p.final_status)
assert(type(r_final.error) == "NA", "final_status (renamed process) should succeed")
z_col = r_final.value.z
assert(get(z_col, 0) == 4, "first row z should be 1+3=4")
assert(get(z_col, 1) == 6, "second row z should be 2+4=6")

r_extra = read_node(final_p.extra_step)
assert(type(r_extra.error) == "NA", "extra_step should succeed")
assert(contains(get(r_extra.value.msg, 0), "extended"), "extra_step message should contain 'extended'")

print("✓ dynamic_pipeline_operator_t: all assertions passed")

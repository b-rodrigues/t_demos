-- nix_orchestration_stress_t
-- Stress testing Nix-native orchestration features and early validation

p = pipeline {
  node_a = [1, 2, 3]
  node_b = node(
    command = <{
      print("Processing node_b")
      node_b = node_a + [4, 5]
    }>,
    deserializer = [node_a: ^default]
  )
  node_c = node(
    command = <{
      print("Processing node_c")
      node_c = node_b + [6]
    }>,
    deserializer = [node_b: ^default]
  )
}

print("=== Test 1: Dry run via populate_pipeline ===")
dry_run_plan = populate_pipeline(
  p,
  build = true,
  dry_run = true,
  verbose = 1,
  max_jobs = 4,
  cache = "rstats-on-nix"
)

if type(dry_run_plan) == "DataFrame" then
  print("✓ populate_pipeline dry_run returned a DataFrame successfully!")
  print("DataFrame Columns:")
  print(names(dry_run_plan))
  print("DataFrame Rows count: " + string(nrow(dry_run_plan)))
else
  error("✗ Expected populate_pipeline(dry_run=true) to return a DataFrame!")
end

print("=== Test 2: Dry run via build_pipeline ===")
build_dry_plan = build_pipeline(
  p,
  dry_run = true,
  verbose = 1
)

if type(build_dry_plan) == "DataFrame" then
  print("✓ build_pipeline dry_run returned a DataFrame successfully!")
else
  error("✗ Expected build_pipeline(dry_run=true) to return a DataFrame!")
end

print("=== Test 3: Early Target Validation ===")
err_targets = build_pipeline(p, targets = ["nonexistent_node"], dry_run = true)
if is_error(err_targets) then
  print("✓ Detected invalid targets list early as expected!")
  print("Error Message: " + error_message(err_targets))
else
  error("✗ build_pipeline should have failed early on nonexistent target!")
end

print("=== Test 4: Early Force Rebuild Validation ===")
err_force = build_pipeline(p, force = ["nonexistent_node"], dry_run = true)
if is_error(err_force) then
  print("✓ Detected invalid force rebuild list early as expected!")
  print("Error Message: " + error_message(err_force))
else
  error("✗ build_pipeline should have failed early on nonexistent force target!")
end

print("=== Test 5: Selective build via populate_pipeline ===")
selective_path = populate_pipeline(
  p,
  build = true,
  targets = ["node_a"],
  verbose = 1
)

print("✓ populate_pipeline selective build completed! Output path:")
print(selective_path)

print("=== Test 6: Full build via build_pipeline ===")
full_build_log = build_pipeline(p, verbose = 1)
print("✓ build_pipeline full build completed successfully!")
print("Build log type: " + type(full_build_log))

-- Copy artifacts locally
pipeline_copy()
print("✓ pipeline_copy executed successfully!")

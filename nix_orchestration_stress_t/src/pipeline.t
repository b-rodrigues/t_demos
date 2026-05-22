-- nix_orchestration_stress_t
-- Stress testing Nix-native orchestration features and early validation

p = pipeline {
  node_a = [1, 2, 3]
  node_b = node(
    command = <{
      print("Processing node_b")
      sum(node_a) + 9
    }>
  )
  node_c = node(
    command = <{
      print("Processing node_c")
      node_b + 6
    }>
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

if (type(dry_run_plan) == "DataFrame") {
  print("✓ populate_pipeline dry_run returned a DataFrame successfully!")
  print("DataFrame Columns:")
  print(colnames(dry_run_plan))
  print(str_join(["DataFrame Rows count: ", to_string(nrow(dry_run_plan))]))
} else {
  error("✗ Expected populate_pipeline(dry_run=true) to return a DataFrame!")
}

print("=== Test 2: Dry run via build_pipeline ===")
build_dry_plan = build_pipeline(
  p,
  dry_run = true,
  verbose = 1
)

if (type(build_dry_plan) == "DataFrame") {
  print("✓ build_pipeline dry_run returned a DataFrame successfully!")
} else {
  error("✗ Expected build_pipeline(dry_run=true) to return a DataFrame!")
}

print("=== Test 3: Selective build via populate_pipeline ===")
selective_path = populate_pipeline(
  p,
  build = true,
  targets = ["node_a"],
  verbose = 1
)

print("✓ populate_pipeline selective build completed! Output path:")
print(selective_path)

print("=== Test 4: Full build via build_pipeline ===")
full_build_log = build_pipeline(p, verbose = 1)
print("✓ build_pipeline full build completed successfully!")
print(str_join(["Build log type: ", type(full_build_log)]))

-- Copy artifacts locally
pipeline_copy()
print("✓ pipeline_copy executed successfully!")

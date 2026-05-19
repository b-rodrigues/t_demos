p = pipeline {
  step1 = command = <{
    "This is step 1"
  }>,

  step2 = command = <{
    "This is step 2"
  }>,

  error_step = command = <{
    error("This node intentionally soft-fails to demonstrate collect_errors!")
  }>
}

# The Github Actions workflow will run this script to populate the Nix pipeline
build_pipeline(p)

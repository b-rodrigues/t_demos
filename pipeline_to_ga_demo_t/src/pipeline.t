-- pipeline_to_ga_demo_t: verify pipeline_to_ga generates expected workflow YAML

p = pipeline {
  x = 1
}

-- Generate the GA workflow YAML to a working location for snapshot diff
pipeline_to_ga(file = "_pipeline/workflow.yml")

assert(file_exists("_pipeline/workflow.yml"), "pipeline_to_ga should create _pipeline/workflow.yml")
print("✓ pipeline_to_ga_demo_t: workflow.yml generated")

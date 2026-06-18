-- pipeline_to_ga_demo_t: verify pipeline_to_ga generates expected workflow YAML

p = pipeline {
  x = 1
}

-- Generate the GA workflow YAML to a working location for snapshot diff
pipeline_to_ga(p, file = "_pipeline/workflow.yml")

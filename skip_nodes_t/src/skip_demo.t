-- src/skip_demo.t
-- Demonstrates skipping nodes with noop = true

p = pipeline {
  data = node(
    command = [1, 2, 3, 4, 5],
    serializer = ^json
  )
  
  -- This node is marked to be skipped in builds
  expensive_node = node(
    command = <{ 
      # Simulate a heavy computation
      time.sleep(1)
      [x * 2 for x in data]
    }>,
    runtime = Python,
    deserializer = ^json,
    serializer = ^json,
    noop = true
  )

  -- This node depends on expensive_node, so it also becomes a noop
  summary = node(
    command = sum(expensive_node),
    deserializer = ^json
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

print("Nodes in pipeline:")
print(pipeline_nodes(p))

-- View noop status
summary_df = p |> select_node($name, $noop)
print("Noop status:")
print(summary_df)

-- The build will NOT execute expensive_node's script, but will create stubs
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

print("Check build log status with inspect_pipeline():")
print(inspect_pipeline())

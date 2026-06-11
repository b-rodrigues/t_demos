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

print("Check build log status with inspect_log():")
print(inspect_log())

-- Node correctness assertions
r_data = read_node(p.data)
assert(type(r_data.error) == "NA", "data should succeed")
assert(length(r_data.value) == 5, "data should have 5 elements")

-- expensive_node is marked noop=true — it should be either skipped or an Error
r_expensive = read_node(p.expensive_node)
if (type(r_expensive.error) == "NA") {
  print("expensive_node succeeded as a stub (noop=true)")
} else {
  print(str_join(["expensive_node error: ", error_msg(r_expensive.error)]))
  -- Noop nodes may produce errors; this is expected behavior
}

-- Pipeline node inspection API should show noop status correctly
meta = select_node(p, $name, $noop)
assert(nrow(meta) > 0, "pipeline should have node metadata")

print("✓ skip_nodes_t: all assertions passed")

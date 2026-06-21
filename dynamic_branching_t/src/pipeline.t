import strcraft
import colcraft

p = pipeline {
  fixed_radii = [3, 5, 8]
  cycling_radii = [2, 4, 6]

  points = node(
    command = <{
      import "src/spirograph.t"
      spirograph_points(fixed_radii, cycling_radii)
    }>,
    pattern = cross_pattern(map_pattern(fixed_radii), map_pattern(cycling_radii)),
    runtime = T,
    serializer = ^json
  )

  single_plot = node(
    command = <{ plot_spirographs(points) }>,
    pattern = map_pattern(points),
    functions = ["src/spirograph.R"],
    runtime = R,
    deserializer = ^json
  )
}

print("=========================================")
print("Dynamic Branching Demo (targets-inspired)")
print("=========================================")
print("fixed_radii = [3, 5, 8]  (3 values)")
print("cycling_radii = [2, 4, 6]  (3 values)")
print("cross_pattern → 9 spirograph data branches")
print("map_pattern → 9 ggplot branches")

res = build_pipeline(p, verbose = 1)

if (is_error(res)) {
  print("Pipeline build failed:")
  print(res)

  node_frame = build_log_to_frame(res)
  points_branches = filter(node_frame, \(r) starts_with(r.name, "points"))
  plot_branches = filter(node_frame, \(r) starts_with(r.name, "single_plot"))

  print("Total nodes: ", nrow(node_frame))
  print("Points branches: ", nrow(points_branches))
  print("Single plot branches: ", nrow(plot_branches))

  assert(nrow(points_branches) == 9, "Expected 9 points branches from cross_pattern")
  assert(nrow(plot_branches) == 9, "Expected 9 single_plot branches from map_pattern")

  errors = errored_nodes(p)
  print("Error count: ", length(errors))
} else {
  print("Build successful!")

  node_frame = build_log_to_frame(res)
  points_branches = filter(node_frame, \(r) starts_with(r.name, "points"))
  plot_branches = filter(node_frame, \(r) starts_with(r.name, "single_plot"))

  print("Total nodes: ", nrow(node_frame))
  print("Points branches: ", nrow(points_branches))
  print("Single plot branches: ", nrow(plot_branches))

  assert(nrow(points_branches) == 9, "Expected 9 points branches from cross_pattern")
  assert(nrow(plot_branches) == 9, "Expected 9 single_plot branches from map_pattern")
  assert(length(res.failed_nodes) == 0, "All nodes should build successfully")

  print("✓ dynamic_branching_t: all assertions passed")
}

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
    runtime = T
  )

  single_plot = node(
    command = <{ plot_spirographs(points) }>,
    pattern = map_pattern(points),
    functions = ["src/spirograph.R"],
    runtime = R,
    deserializer = "json"
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
} else {
  print("Build successful!")

  all_nodes = pipeline_nodes(p)

  points_branches = filter(all_nodes, \(n) starts_with(n, "points"))
  plot_branches = filter(all_nodes, \(n) starts_with(n, "single_plot"))

  print("Total nodes: ", length(all_nodes))
  print("Points branches: ", length(points_branches))
  print("Single plot branches: ", length(plot_branches))

  assert(length(points_branches) == 9, "Expected 9 points branches from cross_pattern")
  assert(length(plot_branches) == 9, "Expected 9 single_plot branches from map_pattern")

  errors = errored_nodes(p)
  assert(length(errors) == 0, "All nodes should build successfully")

  r1 = read_node(p.single_plot_branch_1)
  assert(type(r1.error) == "NA", "single_plot_branch_1 should succeed")
  print("Branch 1 class: ", r1.class)
  assert(r1.class == "ggplot", "single_plot_branch_1 should be a ggplot object")

  print("✓ dynamic_branching_t: all assertions passed")
}

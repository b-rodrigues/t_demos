-- pipeline_functions_t
-- Exercise the pipeline inspection, validation, and artifact helpers.

base_p = pipeline {
  raw_data = dataframe([
    [id: 1, group: "alpha", value: 10],
    [id: 2, group: "alpha", value: na()],
    [id: 3, group: "beta", value: 5],
    [id: 4, group: "beta", value: -2]
  ])

  positive_rows = raw_data |> filter($value > 0)

  quiet_positive_rows = raw_data
    |> filter($value > 0)
    |> suppress_warnings

  grouped_rows = quiet_positive_rows |> group_by($group)

  summary = grouped_rows |> summarize($total = sum($value, na_rm = true))
}

edited_p = base_p
  |> rename_node("summary", "final_summary")
  |> patch(pipeline {
    final_summary = grouped_rows |> summarize($total = sum($value, na_rm = true))
  })
  |> mutate_node($noop = false)

print("=== Pipeline structure ===")
print(pipeline_nodes(edited_p))
print(pipeline_deps(edited_p))
print(pipeline_node(edited_p, "raw_data"))
print(pipeline_to_frame(edited_p))
print(pipeline_edges(edited_p))
print(pipeline_roots(edited_p))
print(pipeline_leaves(edited_p))
print(pipeline_depth(edited_p))
print(pipeline_cycles(edited_p))
print(pipeline_summary(edited_p))
print(pipeline_validate(edited_p))
pipeline_assert(edited_p)
pipeline_print(edited_p)
print(pipeline_dot(edited_p))

print("=== In-memory execution ===")
rerun_p = pipeline_run(edited_p)
final_summary_node = pipeline_node(rerun_p, "final_summary")
print(final_summary_node)
print(trace_nodes(rerun_p, ["final_summary"]))

print("=== Materialization ===")
populate_pipeline(edited_p, build = false)
build_pipeline(edited_p, verbose = 1)
print(read_pipeline(edited_p))
print(read_node(edited_p, "final_summary"))
pipeline_copy()
print(inspect_pipeline())
print(list_logs())
print(inspect_node(final_summary_node))
print(rebuild_node(final_summary_node))
print(read_node("final_summary"))

print("Pipeline helper demo complete")

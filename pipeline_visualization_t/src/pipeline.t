-- pipeline_visualization_t pipeline

p = pipeline {
  raw_data = [10, 20, 30, 40, 50]
  processed = raw_data |> map(\(x) x * 2)
  summary_val = sum(processed)
}

-- Create a unique pipeline p_fresh with a different input so it's not cached
p_fresh = pipeline {
  raw_data = [11, 22, 33, 44, 55]
  processed = raw_data |> map(\(x) x * 2)
  summary_val = sum(processed)
}

-- 1. Cache-Aware Dry Run (unbuilt)
print("1. Performing dry-run before any build (should be rebuild):")
plan1 = build_pipeline(p_fresh, dry_run = true)
print("Columns in plan:")
print(colnames(plan1))
print("Plan contents:")
print(plan1)
print(plan1.node)
print(plan1.action)

-- Verify dry run returns a DataFrame with expected columns
assert(type(plan1) == "DataFrame", "dry_run should return a DataFrame")
assert(identical(colnames(plan1), ["node", "action", "store_path"]), "dry_run plan should have 'node', 'action', and 'store_path' columns")
assert(nrow(plan1) == 3, "dry_run plan should have 3 rows for 3 nodes")

-- Verify all actions in plan1 are "rebuild" (fresh pipeline, never built)
action1 = plan1.action .== "rebuild"
all_rebuild = length(action1) == sum(action1)
assert(all_rebuild, "fresh pipeline dry_run should show 'rebuild' for all nodes")

-- 2. Build the pipeline p
print("\n2. Building the pipeline p...")
build_pipeline(p)

-- Verify all p nodes succeeded after build
assert(type(p.raw_data) != "Error", "raw_data should not be an Error")
assert(type(p.processed) != "Error", "processed should not be an Error")
assert(!is_error(p.summary_val), "summary_val should not be an error")
assert(p.summary_val == 300, "summary_val should equal sum of [20,40,60,80,100] = 300")

-- 3. Dry run again (all should be cache_hit now for p)
print("\n3. Performing dry-run after build (should be cache_hit):")
plan2 = build_pipeline(p, dry_run = true)
print(plan2)
print(plan2.node)
print(plan2.action)

-- Verify all actions in plan2 are "cache_hit" (p was just built)
assert(type(plan2) == "DataFrame", "second dry_run should return a DataFrame")
action2 = plan2.action .== "cache_hit"
all_cache_hit = length(action2) == sum(action2)
assert(all_cache_hit, "after build, dry_run should show 'cache_hit' for all nodes")

-- 4. Check show_plot with a pipeline (returns HTML path)
print("\n4. Exercising show_plot(p) on pipeline...")
html_path_p = show_plot(p)
print("Generated pipeline plot HTML path:")
print(html_path_p)
assert(ends_with(html_path_p, ".html"), "pipeline show_plot should return .html path")

-- 5. Check show_plot with a custom Mermaid string (returns HTML path)
print("\n5. Exercising show_plot(...) on a custom Mermaid flowchart...")
mermaid_str = "flowchart TD
  start_node[Start] --> process_node[Process Data]
  process_node --> end_node[Finish]
"
html_path_m = show_plot(mermaid_str)
print("Generated custom Mermaid plot HTML path:")
print(html_path_m)
assert(ends_with(html_path_m, ".html"), "mermaid show_plot should return .html path")

print("\nAll pipeline visualization and dry_run exercises completed successfully!")

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

-- 2. Build the pipeline p
print("\n2. Building the pipeline p...")
build_pipeline(p)

-- 3. Dry run again (all should be cache_hit now for p)
print("\n3. Performing dry-run after build (should be cache_hit):")
plan2 = build_pipeline(p, dry_run = true)
print(plan2)
print(plan2.node)
print(plan2.action)

-- 4. Check show_plot with a pipeline (returns HTML path)
print("\n4. Exercising show_plot(p) on pipeline...")
html_path_p = show_plot(p)
print("Generated pipeline plot HTML path:")
print(html_path_p)
if (ends_with(html_path_p, ".html")) {
  print("✓ Pipeline show_plot successful!")
} else {
  print("✗ Pipeline show_plot failed")
}

-- 5. Check show_plot with a custom Mermaid string (returns HTML path)
print("\n5. Exercising show_plot(...) on a custom Mermaid flowchart...")
mermaid_str = "flowchart TD
  start_node[Start] --> process_node[Process Data]
  process_node --> end_node[Finish]
"
html_path_m = show_plot(mermaid_str)
print("Generated custom Mermaid plot HTML path:")
print(html_path_m)
if (ends_with(html_path_m, ".html")) {
  print("✓ Mermaid string show_plot successful!")
} else {
  print("✗ Mermaid string show_plot failed")
}

print("\nAll pipeline visualization and dry_run exercises completed successfully!")

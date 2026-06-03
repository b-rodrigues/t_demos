import "src/pipeline_def.t"[p]

print("=== 1. Building Pipeline ===")
populate_pipeline(p, build = true, verbose = 1)

print("=== 2. Exporting Pipeline Cache ===")
export_artifacts(p, "/tmp/p_all.nar")
export_artifacts(p.node1, "/tmp/node1_only.nar")
export_artifacts([p.node1, p.node2], "/tmp/nodes_list.nar")

print("=== 3. Introspecting Archive Metadata ===")
df_all = inspect_artifacts("/tmp/p_all.nar")
print("Full pipeline archive inspection dataframe:")
print(df_all)

df_node1 = inspect_artifacts("/tmp/node1_only.nar")
print("Single node archive inspection dataframe:")
print(df_node1)

df_list = inspect_artifacts("/tmp/nodes_list.nar")
print("List of nodes archive inspection dataframe:")
print(df_list)

print("=== 4. Variadic / Verification Cache Imports ===")
import_artifacts(p.node1, "/tmp/node1_only.nar")
print("Verified and imported node1 successfully!")

import_artifacts("/tmp/p_all.nar")
print("Unconditionally imported all nodes successfully!")

print("=== 5. Cache-Aware Dry Runs ===")
dry_run_plan = populate_pipeline(p, dry_run = true)
print("Dry run plan DataFrame:")
print(dry_run_plan)

print("=== 6. Programmatic Garbage Collection ===")
gc_preview = pipeline_gc(p, dry_run = true)
print("Pipeline GC preview DataFrame:")
print(gc_preview)

print("Running global garbage collection...")
gc_result = t_gc()
print(gc_result)

print("=== E2E Cache Transfer Integration Tests Completed ===")

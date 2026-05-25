-- diff_history_t/src/pipeline.t
--
-- A comprehensive demo showcasing T-Lang's temporal introspection features:
-- build_log_history() and node_diff()

-- 1. Initialize our dynamic dataset file for Version 1
write_text("data.csv", "x,y\n1,10\n2,20\n3,30\n")

p1 = pipeline {
  data = node(
    command = <{ read_csv("data.csv") }>,
    serializer = ^csv
  )
  scalar = 100
  text_node = node(
    command = <{ "Version 1 text content\nLine two\n" }>,
    runtime = T,
    serializer = ^text
  )
}

print("=========================================")
print("=== Phase 1: Building Pipeline Version 1 ===")
print("=========================================")
res1 = build_pipeline(p1)
print("Version 1 built. Success:", is_error(res1) == false)
print("")

-- 2. Update the dataset, scalar, and text values for Version 2 (schema and values change)
write_text("data.csv", "x,y,z\n1,10.5,100\n2,21.0,200\n3,31.5,300\n")

p2 = pipeline {
  data = node(
    command = <{ read_csv("data.csv") }>,
    serializer = ^csv
  )
  scalar = 150
  text_node = node(
    command = <{ "Version 2 text content\nLine two modified\nLine three added\n" }>,
    runtime = T,
    serializer = ^text
  )
}

print("=========================================")
print("=== Phase 2: Building Pipeline Version 2 ===")
print("=========================================")
res2 = build_pipeline(p2)
print("Version 2 built. Success:", is_error(res2) == false)
print("")

-- 3. Update the dataset, scalar, and text values for Version 3
write_text("data.csv", "x,y,z\n1,12.5,100\n2,25.0,200\n3,37.5,300\n")

p3 = pipeline {
  data = node(
    command = <{ read_csv("data.csv") }>,
    serializer = ^csv
  )
  scalar = 200
  text_node = node(
    command = <{ "Version 3 text content\nLine two modified\nLine three added\nLine four added\n" }>,
    runtime = T,
    serializer = ^text
  )
}

print("=========================================")
print("=== Phase 3: Building Pipeline Version 3 ===")
print("=========================================")
res3 = build_pipeline(p3)
print("Version 3 built. Success:", is_error(res3) == false)
print("")

-- 4. Temporal Introspection: Querying History and Diffs
print("=========================================")
print("=== Phase 4: Querying Build History   ===")
print("=========================================")
hist = build_log_history(p3)
print("Build history dataframe structure:")
glimpse(hist)
print("")

print("=========================================")
print("=== Phase 5: Comparing Scalar Node    ===")
print("=========================================")
-- Compare build 1 (latest/V3) vs build 2 (second latest/V2)
diff_scalar = node_diff(p3, "scalar", 1, 2)
print("Scalar node 'scalar' diff results:")
print("  - Changed?          ", diff_scalar.changed)
print("  - Value A (latest): ", diff_scalar.value_a)
print("  - Value B (V2):     ", diff_scalar.value_b)
print("  - Numeric Delta:    ", diff_scalar.delta)
print("")

print("=========================================")
print("=== Phase 6: Comparing DataFrame Node ===")
print("=========================================")
-- Compare build 1 (latest/V3) vs build 2 (second latest/V2)
diff_df = node_diff(p3, "data", 1, 2)
print("DataFrame node 'data' diff results:")
print("  - Schema Changed?   ", diff_df.schema_changed)
print("  - Added Columns:    ", diff_df.added_columns)
print("  - Removed Columns:  ", diff_df.removed_columns)
print("  - Rows in A (latest):", diff_df.nrows_a)
print("  - Rows in B (V2):    ", diff_df.nrows_b)
print("  - Column summaries:")
glimpse(diff_df.column_summaries)
print("")

print("=========================================")
print("=== Phase 7: Comparing Text Node      ===")
print("=========================================")
-- Compare build 1 (latest/V3) vs build 2 (second latest/V2)
diff_text = node_diff(p3, "text_node", 1, 2)
print("Text node 'text_node' diff results:")
print("  - Changed?          ", diff_text.changed)
print("  - Lines Added:      ", diff_text.lines_added)
print("  - Lines Removed:    ", diff_text.lines_removed)
print("  - Raw Unified Diff:")
print(diff_text.diff)
print("")

print("=========================================")
print("=== Phase 8: Introspection Demo Complete  ===")
print("=========================================")

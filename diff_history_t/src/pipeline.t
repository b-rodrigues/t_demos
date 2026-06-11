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
-- Compare p3.scalar (latest/V3) vs p2.scalar (V2)
diff_scalar = node_diff(p3.scalar, p2.scalar)
print("Scalar node 'scalar' diff results:")
print("  - Changed?          ", diff_scalar.summary.changed)
print("  - Value A (latest): ", diff_scalar.summary.value_a)
print("  - Value B (V2):     ", diff_scalar.summary.value_b)
print("  - Numeric Delta:    ", diff_scalar.summary.delta)
print("")

print("=========================================")
print("=== Phase 6: Comparing DataFrame Node ===")
print("=========================================")
-- Compare p3.data (latest/V3) vs p2.data (V2)
diff_df = node_diff(p3.data, p2.data)
print("DataFrame node 'data' diff results:")
print("  - Schema Changed?   ", (length(diff_df.summary.cols_added) > 0 || length(diff_df.summary.cols_removed) > 0))
print("  - Added Columns:    ", diff_df.summary.cols_added)
print("  - Removed Columns:  ", diff_df.summary.cols_removed)
print("  - Rows in A (latest):", (diff_df.summary.rows_removed + diff_df.summary.rows_changed + diff_df.summary.rows_unchanged))
print("  - Rows in B (V2):    ", (diff_df.summary.rows_added + diff_df.summary.rows_changed + diff_df.summary.rows_unchanged))
print("  - Rows Added:       ", diff_df.summary.rows_added)
print("  - Rows Removed:     ", diff_df.summary.rows_removed)
print("  - Rows Changed:     ", diff_df.summary.rows_changed)
print("Detailed git-like Diff of DataFrame rows:")
print(diff_df.detailed_summary)
print("")

print("=========================================")
print("=== Phase 7: Comparing Text Node      ===")
print("=========================================")
-- Compare p3.text_node (latest/V3) vs p2.text_node (V2)
diff_text = node_diff(p3.text_node, p2.text_node)
print("Text node 'text_node' diff results:")
print("  - Changed?          ", diff_text.summary.changed)
print("  - Value A (latest): ", diff_text.summary.value_a)
print("  - Value B (V2):     ", diff_text.summary.value_b)
print("  - Number of Hunks:  ", length(diff_text.hunks))
print("Detailed git-like Diff of Text content:")
print(diff_text.detailed_summary)
print("")

print("=========================================")
print("=== Phase 8: Writing Diffs to Disk    ===")
print("=========================================")
write_text("df_diff.diff", diff_df.detailed_summary)
write_text("text_diff.diff", diff_text.detailed_summary)
print("Successfully wrote df_diff.diff and text_diff.diff to disk.")
print("")

print("=========================================")
print("=== Phase 9: Introspection Demo Complete  ===")
print("=========================================")

-- Build completion assertions
assert(!is_error(res1), "Version 1 build should succeed")
assert(!is_error(res2), "Version 2 build should succeed")
assert(!is_error(res3), "Version 3 build should succeed")

-- Build history assertions
assert(nrow(hist) == 3, "build_log_history should have 3 entries (3 versions)")

-- Scalar diff assertions
assert(diff_scalar.summary.changed == true, "scalar should have changed between V2 and V3")
assert(diff_scalar.summary.value_a == 200, "scalar V3 value should be 200")
assert(diff_scalar.summary.value_b == 150, "scalar V2 value should be 150")
assert(diff_scalar.summary.delta == 50, "scalar delta should be 50")

-- DataFrame diff assertions
assert(diff_df.summary.changed == true, "data should have changed between V2 and V3")
assert(diff_df.summary.rows_changed == 3, "all 3 data rows should show as changed (y values differ)")

-- Text diff assertions
assert(diff_text.summary.changed == true, "text should have changed between V2 and V3")
assert(length(diff_text.hunks) > 0, "text diff should have at least 1 hunk")
assert(contains(diff_text.detailed_summary, "Version 3"), "diff should reference V3 content")

print("✓ diff_history_t: all assertions passed")

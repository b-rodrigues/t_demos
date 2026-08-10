-- check_fix_diff_t: Demonstrates t check, t fix, and t diff
--
-- Run:  t check --schema src/pipeline.t      (static validation)
-- Run:  t run src/pipeline.t                 (full pipeline build + assertions)
-- Run:  t diff src/pipeline.t                (compare last two builds)

import dataframe
import colcraft

-- ── Build pipeline ─────────────────────────────────────────────────────────────
p = pipeline {
  raw = read_csv("data/sales.csv")

  clean = raw |> filter($amount > 0)

  summary_node = clean |> summarize(
    $total = sum($amount),
    $n = nrow(clean)
  )
}

-- Build is skipped in check mode (t check), runs normally in run mode (t run)
res = populate_pipeline(p, build = true)

-- In check mode, populate_pipeline returns a string (not an error).
-- Only run assertions when the pipeline actually built.
built = !is_error(res) && type(res) != "String"

if (built) {
  clean_df = read_node(p.clean)
  assert(!is_error(clean_df), "clean node errored")
  assert(!is_error(read_node(p.summary_node)), "summary node errored")

  -- Runtime contract checks on the built output (testcraft)
  assert(expect_colnames(clean_df, ["id", "amount", "date", "status"]), "clean has expected columns")
  assert(expect_column_types(clean_df, [amount: "Float"]), "amount column is a double")
  assert(expect_no_na(clean_df, "amount"), "amount column has no NAs")

  print("=== Clean data (first 5 rows) ===")
  print(head(clean_df))

  print("")
  print("=== Summary ===")
  print(read_node(p.summary_node).value)

  print("")
  print("=== Pipeline Diagnostics ===")
  print(read_pipeline(p).diagnostics.summary)

  print("")
  print("=== Build Diff Summary ===")
  diff = diff_summary(p)
  if (is_error(diff)) {
    print("(run 't run src/pipeline.t' twice to see build diffs)")
  } else {
    print(diff)
  }
}

"check_fix_diff_t demo passed"

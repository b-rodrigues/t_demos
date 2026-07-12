-- check_fix_diff_t: Demonstrates expect() contracts, t check, t fix, and t diff
--
-- Run:  t check --schema src/pipeline.t      (static contract validation)
-- Run:  t run src/pipeline.t                 (full pipeline build + assertions)
-- Run:  t diff src/pipeline.t                (compare last two builds)

import dataframe
import colcraft

-- ── Build pipeline ─────────────────────────────────────────────────────────────
-- expect() contracts are declared inside pipeline nodes:
--   Column contract:  output must have exactly these 4 columns
--   Type contract:    amount must be double (verified statically via t check --schema)
--   Null-rate contract: amount must have < 5% nulls (deferred to runtime)
p = pipeline {
  raw = read_csv("data/sales.csv")

  clean = raw
    |> filter($amount > 0)
    |> expect(
         columns = ["id", "amount", "date", "status"],
         amount ~ double(),
         null_rate("amount") < 0.05
       )

  summary = clean |> summarize(
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
  assert(!is_error(read_node(p.clean)), "clean node errored")
  assert(!is_error(read_node(p.summary)), "summary node errored")

  print("=== Clean data (first 5 rows) ===")
  print(head(clean))

  print("")
  print("=== Summary ===")
  print(read_node(p.summary).value)

  print("")
  print("=== Pipeline Diagnostics ===")
  print(read_pipeline(p).diagnostics.summary)

  print("")
  print("=== Build Diff Summary ===")
  diff = diff_summary(p)
  if (nrow(diff) > 0) {
    print(diff)
  } else {
    print("(run 't run src/pipeline.t' twice to see build diffs)")
  }
}

"check_fix_diff_t demo passed"

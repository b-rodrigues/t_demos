-- test_runner_features_t/src/pipeline.t
--
-- Exercises:
--   chain() + parallel() fixture pattern with separated data and test nodes
--   (Data transformation node -> Test result dictionary node)
--
-- Run with: t run src/pipeline.t or via t_make() in REPL

-- === Fixture Pipeline Pattern ===
-- A fixture pipeline produces base data; downstream test pipelines
-- consume it to perform transformations and capture test results in separate nodes.

fixture = pipeline {
  data = node(
    command = read_csv("tests/data/sample.csv"),
    serializer = ^csv
  )
}

test_filter = pipeline {
  -- Data transformation node (consumes CSV data, produces CSV filtered_data)
  filtered_data = node(
    command = data |> filter($score >= 88),
    serializer = ^csv,
    deserializer = ^csv
  )
  -- Test node (consumes CSV filtered_data, returns named Dict of assertion results)
  -- On success: serializes [ nrow_check: true, colnames_check: true ] as JSON
  -- On failure: assert short-circuits and captures VError failure object
  check_filter = node(
    command = [
      nrow_check: assert(expect_nrow(filtered_data, 2)),
      colnames_check: assert(expect_colnames(filtered_data, ["name", "score", "grade"]))
    ],
    serializer = ^json,
    deserializer = ^csv
  )
}

test_mutate = pipeline {
  -- Data transformation node (consumes CSV data, produces CSV mutated_data)
  mutated_data = node(
    command = data |> mutate($pass = $score >= 70),
    serializer = ^csv,
    deserializer = ^csv
  )
  -- Test node (consumes CSV mutated_data, returns named Dict of assertion results)
  -- On success: serializes [ pass_col_check: true, pass_count_check: true ] as JSON
  -- On failure: assert short-circuits and captures VError failure object
  check_mutate = node(
    command = [
      pass_col_check: assert(expect_in("pass", colnames(mutated_data))),
      pass_count_check: assert(expect_nrow(mutated_data |> filter($pass == true), 4))
    ],
    serializer = ^json,
    deserializer = ^csv
  )
}

-- chain() wires fixture.data into both test pipelines;
-- parallel() runs them independently with separated data & check nodes
combined = chain(fixture, parallel(test_filter, test_mutate))
res = build_pipeline(combined)
pipeline_copy()

if (is_error(res)) {
  error(str_join(["Fixture pipeline build failed: ", error_msg(res)]))
}

print("Fixture pipeline: chain + parallel with separated transformation & test result dict nodes all passed")

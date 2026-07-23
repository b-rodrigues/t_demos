-- test_runner_features_t/src/pipeline.t
--
-- Exercises:
--   chain() + parallel() fixture pattern with separated data and test nodes
--   (Data transformation node -> Test assertion node)
--
-- Run with: t run src/pipeline.t or via t_make() in REPL

-- === Fixture Pipeline Pattern ===
-- A fixture pipeline produces base data; downstream test pipelines
-- consume it to perform transformations and execute assertions in separate nodes.

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
  -- Test assertion node (consumes CSV filtered_data, returns text status)
  check_filter = node(
    command = {
      assert(expect_nrow(filtered_data, 3))
      assert(expect_colnames(filtered_data, ["name", "score", "grade"]))
      "check_filter passed"
    },
    serializer = ^text,
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
  -- Test assertion node (consumes CSV mutated_data, returns text status)
  check_mutate = node(
    command = {
      assert(expect_in("pass", colnames(mutated_data)))
      assert(expect_nrow(mutated_data |> filter($pass == true), 4))
      "check_mutate passed"
    },
    serializer = ^text,
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

print("Fixture pipeline: chain + parallel with separated transformation & check nodes all passed")

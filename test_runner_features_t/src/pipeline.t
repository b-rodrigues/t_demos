-- test_runner_features_t/src/pipeline.t
--
-- Exercises:
--   1. t_test() REPL function (returns DataFrame)
--   2. chain() + parallel() fixture pattern (shared test data via DAG)
-- Run with: t run src/pipeline.t

-- === 1. t_test() REPL Function ===

results = t_test()

assert(expect_type(results, "DataFrame"))
assert(expect_colnames(results, ["file", "status", "duration_ms", "error"]))

-- .tignore excludes test_slow.t and test_wip.t, so 3 tests remain
assert(expect_nrow(results, 3))

-- All remaining tests should pass
failed = results |> filter($status == "failed")
assert(expect_nrow(failed, 0))

print("t_test() passed: all 3 non-ignored tests green")

-- === 2. Fixture Pipeline Pattern ===
-- A fixture pipeline produces data once; multiple test pipelines
-- consume it independently via chain() and parallel().

fixture = pipeline {
  data = node(
    command = read_csv("tests/data/sample.csv"),
    serializer = ^csv
  )
}

test_filter = pipeline {
  check_filter = node(
    command = {
      result = data |> filter($score >= 88)
      assert(expect_nrow(result, 2))
      assert(expect_colnames(result, ["name", "score", "grade"]))
    },
    serializer = ^csv
  )
}

test_mutate = pipeline {
  check_mutate = node(
    command = {
      result = data |> mutate($pass = $score >= 70)
      assert(expect_in("pass", colnames(result)))
      assert(expect_nrow(result |> filter($pass == true), 4))
    },
    serializer = ^csv
  )
}

-- chain() wires fixture.data into both test pipelines;
-- parallel() runs them independently (unique node names required)
combined = chain(fixture, parallel(test_filter, test_mutate))
res = build_pipeline(combined)
pipeline_copy()

if (is_error(res)) {
  error(str_join(["Fixture pipeline build failed: ", error_msg(res)]))
}

print("Fixture pipeline: chain + parallel all tests passed")

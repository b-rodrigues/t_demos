-- test_runner_features_t/src/pipeline.t
--
-- Exercises the t_test() REPL function, which returns a DataFrame.
-- Run with: t run src/pipeline.t

results = t_test()

-- Verify the result is a well-formed DataFrame
assert(expect_type(results, "DataFrame"))
assert(expect_colnames(results, ["file", "status", "duration_ms", "error"]))

-- .tignore excludes test_slow.t and test_wip.t, so 3 tests remain
assert(expect_nrow(results, 3))

-- All remaining tests should pass
failed = results |> filter($status == "failed")
assert(expect_nrow(failed, 0))

print("t_test() passed: all 3 non-ignored tests green")

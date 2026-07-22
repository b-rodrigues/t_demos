-- testcraft_expectations_t — comprehensive demonstration of all Testcraft expectation primitives
--
-- Run with: t run src/pipeline.t

-- 1. Pipeline Definition with Test Nodes & Patterns
p = pipeline {
  raw_data = to_dataframe([id: [1, 2, 3, 4], val: [10.5, 20.0, 30.5, 40.0]])

  -- Check raw dataset properties inline
  check_raw = node(
    command = {
      assert(expect_nrow(raw_data, 4))
      assert(expect_ncol(raw_data, 2))
      assert(expect_colnames(raw_data, ["id", "val"]))
    },
    runtime = T
  )

  -- Transform data in T
  processed = raw_data |> filter($val > 15.0)

  -- Node with dynamic branching pattern
  branch_data = node(command = 1, pattern = map_pattern(raw_data))
}

-- 2. Materialize Pipeline & Explicit Error Guards
res = populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

if (is_error(res)) {
  error(str_join(["Pipeline build failed: ", error_msg(res)]))
}

if (is_error(p.check_raw)) {
  error(str_join(["Node 'check_raw' errored: ", error_msg(p.check_raw)]))
}

-- 3. Pipeline DAG Expectations
print("=== Testing Pipeline DAG Expectations ===")
check(expect_pipeline(p))
check(expect_nodes(p, ["raw_data", "check_raw", "processed", "branch_data", "branch_data_branch_1", "branch_data_branch_2", "branch_data_branch_3", "branch_data_branch_4"]))
check(expect_dependency(p, "raw_data", "check_raw"))
check(expect_dependency(p, "raw_data", "processed"))
check(expect_has_pattern(p, "branch_data"))
check(expect_runtime(p, "processed", "T"))
check(expect_noop(p, "processed", false))
check(expect_computed(p.processed))

-- 4. Relational / Comparison Expectations
print("=== Testing Relational Expectations ===")
check(expect_gt(10, 5))
check(expect_gte(10, 10))
check(expect_lt(5, 10))
check(expect_lte(5, 5))

-- 5. Equality & Meta Expectations
print("=== Testing Equality & Meta Expectations ===")
pass_val = expect_equal([1, 2, 3], [1, 2, 3])
check(expect_pass(pass_val))
check(expect_true(expect_pass(pass_val)))
check(expect_false(expect_fail(pass_val)))

fail_val = expect_equal(1, 2)
check(expect_fail(fail_val))
check(expect_type(expect_msg(fail_val), "String"))

-- 6. Type & Logic Expectations
print("=== Testing Type & Logic Expectations ===")
check(expect_truthy(10))
check(expect_truthy("hello"))
check(expect_falsy(false))
check(expect_type(42, "Int"))
check(expect_type(to_dataframe([a: [1]]), "DataFrame"))
check(expect_length([1, 2, 3, 4], 4))

-- 7. Data Structure & Field Expectations
print("=== Testing Data Structure Expectations ===")
dict_val = [a: 100, b: 200]
check(expect_fields(dict_val, ["a", "b"]))
check(expect_in(20, [10, 20, 30]))
check(expect_in("b", ["a", "b", "c"]))

-- 8. Condition & Error Expectations
print("=== Testing Condition & Error Expectations ===")
check(expect_error(error("Sample test failure"), class = "GenericError"))

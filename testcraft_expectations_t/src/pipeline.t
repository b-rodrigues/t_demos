-- testcraft_expectations_t — comprehensive demonstration of all Testcraft expectation primitives
--
-- Run with: t run src/pipeline.t

-- 1. Pipeline Definition with Test Nodes
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
}

-- 2. Materialize Pipeline
res = populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- 3. Pipeline DAG Expectations
print("=== Testing Pipeline DAG Expectations ===")
assert(expect_pipeline(p))
assert(expect_nodes(p, ["raw_data", "check_raw", "processed"]))
assert(expect_dependency(p, "raw_data", "check_raw"))
assert(expect_dependency(p, "raw_data", "processed"))
assert(expect_has_pattern(p, "check_*"))
assert(expect_runtime(p, "processed", ^T))
assert(expect_noop(p, "processed", false))
assert(expect_computed(p.processed))

-- 4. Relational / Comparison Expectations
print("=== Testing Relational Expectations ===")
assert(expect_gt(10, 5))
assert(expect_gte(10, 10))
assert(expect_ge(10, 10))
assert(expect_lt(5, 10))
assert(expect_lte(5, 5))
assert(expect_le(5, 5))

-- 5. Equality & Meta Expectations
print("=== Testing Equality & Meta Expectations ===")
pass_val = expect_equal([1, 2, 3], [1, 2, 3])
assert(expect_pass(pass_val))
assert(expect_true(expect_pass(pass_val)))
assert(expect_false(expect_fail(pass_val)))

fail_val = expect_equal(1, 2)
assert(expect_fail(fail_val))
assert(expect_type(expect_msg(fail_val), "String"))

-- 6. Type & Logic Expectations
print("=== Testing Type & Logic Expectations ===")
assert(expect_truthy(10))
assert(expect_truthy("hello"))
assert(expect_falsy(false))
assert(expect_type(42, "Int"))
assert(expect_type(to_dataframe([a: [1]]), "DataFrame"))
assert(expect_length([1, 2, 3, 4], 4))

-- 7. Data Structure & Field Expectations
print("=== Testing Data Structure Expectations ===")
dict_val = [a: 100, b: 200]
assert(expect_fields(dict_val, ["a", "b"]))
assert(expect_in(20, [10, 20, 30]))
assert(expect_in("b", ["a", "b", "c"]))

-- 8. Condition & Error Expectations
print("=== Testing Condition & Error Expectations ===")
assert(expect_error(error("Sample test failure"), class = "RuntimeError"))
assert(expect_warning(suppress_warnings(read_node(p.processed))))

print("🎉 testcraft_expectations_t: all assertions passed successfully!")

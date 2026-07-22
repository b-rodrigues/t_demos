-- test_arithmetic.t — basic math assertions
--
-- Exercises expect_equal, expect_gt, expect_lt, expect_gte, expect_lte

assert(expect_equal(2 + 2, 4))
assert(expect_equal(10 * 3, 30))
assert(expect_equal(100 / 4, 25))
assert(expect_gt(10, 5))
assert(expect_lt(3, 7))
assert(expect_gte(10, 10))
assert(expect_lte(5, 5))
assert(expect_equal(0.1 + 0.2, 0.3, tolerance = 1e-9))

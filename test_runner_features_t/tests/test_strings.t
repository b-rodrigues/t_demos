-- test_strings.t — string operation assertions
--
-- Exercises expect_equal, expect_type on string operations

assert(expect_equal(str_upper("hello"), "HELLO"))
assert(expect_equal(str_lower("WORLD"), "world"))
assert(expect_equal(str_len("abc"), 3))
assert(expect_type("hello", "String"))
assert(expect_type(str_join(["a", "b"], ", "), "String"))

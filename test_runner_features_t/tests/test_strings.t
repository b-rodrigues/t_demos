-- test_strings.t — string operation assertions
--
-- Exercises expect_equal, expect_type on string operations

assert(expect_equal(to_upper("hello"), "HELLO"))
assert(expect_equal(to_lower("WORLD"), "world"))
assert(expect_equal(str_nchar("abc"), 3))
assert(expect_type("hello", "String"))
assert(expect_type(str_join(["a", "b"], ", "), "String"))

-- test_dataframe.t — DataFrame schema and data assertions
--
-- Reads a CSV fixture and checks structure with expect_* assertions

df = read_csv("tests/data/sample.csv")

assert(expect_type(df, "DataFrame"))
assert(expect_nrow(df, 4))
assert(expect_ncol(df, 3))
assert(expect_colnames(df, ["name", "score", "grade"]))

top = df |> filter($score >= 88)
assert(expect_nrow(top, 2))

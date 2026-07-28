-- pipeline_param_t: parameterizing pipelines via lambdas

-- ============================================================
-- 1. Basic multiplier pipeline (from the tutorial)
-- ============================================================
make_mult_pipeline = \(multiplier: Int -> Pipeline) pipeline {
  raw      = [1, 2, 3]
  computed = raw .* multiplier
}

p1 = make_mult_pipeline(10)
p2 = make_mult_pipeline(20)

populate_pipeline(p1, build = true, verbose = 1)
val1 = read_node(p1.computed)
print(str_join(["p1.computed = ", to_string(val1)], ""))
assert(identical(val1, [10, 20, 30]), "p1 should multiply [1,2,3] by 10")

populate_pipeline(p2, build = true, verbose = 1)
val2 = read_node(p2.computed)
print(str_join(["p2.computed = ", to_string(val2)], ""))
assert(identical(val2, [20, 40, 60]), "p2 should multiply [1,2,3] by 20")

-- ============================================================
-- 2. Multi-parameter pipeline (scale + offset)
-- ============================================================
make_transform_pipeline = \(scale: Int, offset: Int -> Pipeline) pipeline {
  data    = [1, 2, 3, 4, 5]
  scaled  = data .* scale
  shifted = scaled .+ offset
  total   = sum(shifted)
}

p3 = make_transform_pipeline(3, 1)
populate_pipeline(p3, build = true, verbose = 1)
val3 = read_node(p3.total)
-- [1,2,3,4,5] .* 3 = [3,6,9,12,15], .+ 1 = [4,7,10,13,16], sum = 50
print(str_join(["p3.total (scale=3, offset=1) = ", to_string(val3)], ""))
assert(val3 == 50, "transform with scale=3, offset=1 should yield 50")

p4 = make_transform_pipeline(2, 10)
populate_pipeline(p4, build = true, verbose = 1)
val4 = read_node(p4.total)
-- [1,2,3,4,5] .* 2 = [2,4,6,8,10], .+ 10 = [12,14,16,18,20], sum = 80
print(str_join(["p4.total (scale=2, offset=10) = ", to_string(val4)], ""))
assert(val4 == 80, "transform with scale=2, offset=10 should yield 80")

-- Verify independence: different parameter values produce different results
assert(val3 != val4, "different params should produce different results")

-- ============================================================
-- 3. String processing pipeline parameterized by separator
-- ============================================================
make_join_pipeline = \(sep: String -> Pipeline) pipeline {
  words  = ["hello", "world", "from", "T"]
  joined = str_join(words, sep = sep)
  length = str_nchar(joined)
}

p5 = make_join_pipeline(", ")
populate_pipeline(p5, build = true, verbose = 1)
val5 = read_node(p5.joined)
print(str_join(["p5.joined = \"", val5, "\""], ""))
assert(val5 == "hello, world, from, T", "join with comma-space should produce expected string")
p5_len = read_node(p5.length)
assert(p5_len == 21, "length of joined string should be 21")

p6 = make_join_pipeline(" | ")
populate_pipeline(p6, build = true, verbose = 1)
val6 = read_node(p6.joined)
print(str_join(["p6.joined = \"", val6, "\""], ""))
assert(val6 == "hello | world | from | T", "join with pipe should produce expected string")
p6_len = read_node(p6.length)
assert(p6_len == 24, "length of pipe-joined string should be 24")

-- ============================================================
-- 4. Composing results from parameterized pipelines
-- ============================================================
make_scale_pipeline = \(factor: Int -> Pipeline) pipeline {
  scaled = [1, 2, 3] .* factor
}

p8 = make_scale_pipeline(5)
populate_pipeline(p8, build = true, verbose = 1)
scaled_val = read_node(p8.scaled)
-- Compose outside pipeline: apply offset to the read value
result_val = scaled_val |> map(\(x) x + 2)
-- [1,2,3] .* 5 = [5,10,15], .+ 2 = [7,12,17]
print(str_join(["composed result = ", to_string(result_val)], ""))
assert(identical(result_val, [7, 12, 17]), "compose scale=5 then offset=2 should yield [7,12,17]")

-- ============================================================
-- 5. Build preview with dry_run
-- ============================================================
plan = populate_pipeline(p1, dry_run = true)
print("Dry run plan:")
print(plan)
assert(nrow(plan) == 2, "dry run plan should have 2 rows")

print("All pipeline parametrization checks passed!")

logs = list_logs()
print(logs)

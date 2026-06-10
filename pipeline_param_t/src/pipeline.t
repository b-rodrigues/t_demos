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
if (is_error(val1)) error("p1.computed failed")
print(str_sprintf("p1.computed = %s", val1 |> map(\(x) to_string(x)) |> str_join(sep = ", ")))
assert(val1 == [10, 20, 30], "p1 should multiply [1,2,3] by 10")

populate_pipeline(p2, build = true, verbose = 1)
val2 = read_node(p2.computed)
if (is_error(val2)) error("p2.computed failed")
print(str_sprintf("p2.computed = %s", val2 |> map(\(x) to_string(x)) |> str_join(sep = ", ")))
assert(val2 == [20, 40, 60], "p2 should multiply [1,2,3] by 20")

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
if (is_error(val3)) error("p3.total failed")
-- [1,2,3,4,5] .* 3 = [3,6,9,12,15], .+ 1 = [4,7,10,13,16], sum = 50
print(str_sprintf("p3.total (scale=3, offset=1) = %d", val3))
assert(val3 == 50, "transform with scale=3, offset=1 should yield 50")

p4 = make_transform_pipeline(2, 10)
populate_pipeline(p4, build = true, verbose = 1)
val4 = read_node(p4.total)
if (is_error(val4)) error("p4.total failed")
-- [1,2,3,4,5] .* 2 = [2,4,6,8,10], .+ 10 = [12,14,16,18,20], sum = 80
print(str_sprintf("p4.total (scale=2, offset=10) = %d", val4))
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
if (is_error(val5)) error("p5.joined failed")
print(str_sprintf("p5.joined = \"%s\"", val5))
assert(val5 == "hello, world, from, T", "join with comma-space should produce expected string")
p5_len = read_node(p5.length)
if (is_error(p5_len)) error("p5.length failed")
assert(p5_len == 21, "length of joined string should be 21")

p6 = make_join_pipeline(" | ")
populate_pipeline(p6, build = true, verbose = 1)
val6 = read_node(p6.joined)
if (is_error(val6)) error("p6.joined failed")
print(str_sprintf("p6.joined = \"%s\"", val6))
assert(val6 == "hello | world | from | T", "join with pipe should produce expected string")
p6_len = read_node(p6.length)
if (is_error(p6_len)) error("p6.length failed")
assert(p6_len == 21, "length of pipe-joined string should be 21")

-- ============================================================
-- 4. Composing results from parameterized pipelines
-- ============================================================
make_scale_pipeline = \(factor: Int -> Pipeline) pipeline {
  scaled = [1, 2, 3] .* factor
}

p8 = make_scale_pipeline(5)
populate_pipeline(p8, build = true, verbose = 1)
scaled_val = read_node(p8.scaled)
if (is_error(scaled_val)) error("p8.scaled failed")
-- Compose outside pipeline: apply offset to the read value
result_val = scaled_val |> map(\(x) x + 2)
-- [1,2,3] .* 5 = [5,10,15], .+ 2 = [7,12,17]
print(str_sprintf("composed result = %s", result_val |> map(\(x) to_string(x)) |> str_join(sep = ", ")))
assert(result_val == [7, 12, 17], "compose scale=5 then offset=2 should yield [7,12,17]")

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

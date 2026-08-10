-- src/pipeline.t
-- Stress test for all lens types, compositions, and pipeline lens operations.
--
-- Covers:
--   1. DataFrame lens combinations (col_lens, row_lens, filter_lens, compose, modify)
--   2. Nested data deep traversal (6+ level composition)
--   3. Pipeline lens operations (NodeLens, NodeMetaLens, EnvVarLens, filter_lens on Pipeline)
--   4. Pipeline immutability and self-rebind stress
--   5. Custom Dict lenses and edge cases

-- ============================================================
-- Section 1: DataFrame Lens Combinations
-- ============================================================

print("=== Section 1: DataFrame Lens Combinations ===")

-- 1a. col_lens: get, set, over on DataFrame
df1 = to_dataframe([
    [name: "Alice", score: 80, grade: "B"],
    [name: "Bob", score: 90, grade: "A"],
    [name: "Carol", score: 70, grade: "C"]
])

score_l = col_lens("score")
df1_boosted = df1 |> over(score_l, \(s) s .+ 5)
assert(get(df1_boosted.score, 0) == 85, "col_lens over: Alice score +5")
assert(get(df1_boosted.score, 1) == 95, "col_lens over: Bob score +5")
assert(get(df1_boosted.score, 2) == 75, "col_lens over: Carol score +5")

-- 1b. col_lens set with recycling (shorter vector)
df2 = to_dataframe([
    [x: 1, y: 10],
    [x: 2, y: 20],
    [x: 3, y: 30],
    [x: 4, y: 40]
])
short_vals = pull(to_dataframe([[v: 99], [v: 88]]), "v")
df2_replaced = set(df2, col_lens("y"), short_vals)
assert(get(df2_replaced.y, 0) == 99, "col_lens recycling: row 0")
assert(get(df2_replaced.y, 1) == 88, "col_lens recycling: row 1")
assert(get(df2_replaced.y, 2) == 99, "col_lens recycling: row 2 (mod)")
assert(get(df2_replaced.y, 3) == 88, "col_lens recycling: row 3 (mod)")

-- 1c. col_lens set adds new column
df3 = to_dataframe([[a: 1, b: 2], [a: 3, b: 4]])
df3_new = set(df3, col_lens("c"), [10, 20])
assert(get(df3_new.c, 0) == 10, "col_lens add column: row 0")
assert(get(df3_new.c, 1) == 20, "col_lens add column: row 1")

-- 1d. row_lens: get, set, partial Dict
df4 = to_dataframe([
    [id: "X", val: 100, flag: true],
    [id: "Y", val: 200, flag: false]
])

-- Full Dict replacement
row0_l = row_lens(0)
df4_updated = set(df4, row0_l, [id: "X", val: 999, flag: false])
assert(get(df4_updated.val, 0) == 999, "row_lens full replace: val")
assert(get(df4_updated.flag, 0) == false, "row_lens full replace: flag")
assert(get(df4_updated.val, 1) == 200, "row_lens full replace: untouched row")

-- Partial Dict: missing columns filled with NA, new columns added
df5 = set(df4, row_lens(0), [id: "Z", extra: 42])
r0 = get(df5, row_lens(0))
assert(r0.id == "Z", "row_lens partial: id replaced")
assert(is_na(r0.flag) == true, "row_lens partial: flag filled with NA")
assert(r0.extra == 42, "row_lens partial: new column added")

-- 1e. filter_lens on DataFrame
df6 = to_dataframe([
    [name: "a", val: 10],
    [name: "b", val: 20],
    [name: "c", val: 30],
    [name: "d", val: 40]
])
high_l = filter_lens(\(r) r.val >= 30)
df6_filtered = set(df6, high_l, [name: "HIGH", val: 999])
assert(get(df6_filtered.val, 0) == 10, "filter_lens set: untouched low")
assert(get(df6_filtered.val, 1) == 20, "filter_lens set: untouched low")
assert(get(df6_filtered.val, 2) == 999, "filter_lens set: matched row 2")
assert(get(df6_filtered.val, 3) == 999, "filter_lens set: matched row 3")

-- filter_lens over on DataFrame
df7 = over(df6, high_l, \(r) mutate(r, $val = $val .* 10))
assert(get(df7.val, 0) == 10, "filter_lens over: untouched low")
assert(get(df7.val, 2) == 300, "filter_lens over: matched row 2 * 10")
assert(get(df7.val, 3) == 400, "filter_lens over: matched row 3 * 10")

-- 1f. compose(row_lens, col_lens) precision cell edit
df8 = to_dataframe([[x: 1, y: 2, z: 3], [x: 4, y: 5, z: 6]])
cell_l = compose(row_lens(1), col_lens("y"))
df8_cell = set(df8, cell_l, 999)
assert(get(df8_cell.y, 0) == 2, "compose(row, col): untouched row 0")
assert(get(df8_cell.y, 1) == 999, "compose(row, col): row 1 updated")

-- 1g. compose(filter_lens, col_lens) filter + transform
df9 = to_dataframe([[x: 1, y: 10], [x: 2, y: 20], [x: 3, y: 30]])
filter_y_l = compose(filter_lens(\(r) r.x > 1), col_lens("y"))
df9_transformed = over(df9, filter_y_l, \(v) v .+ 100)
assert(get(df9_transformed.y, 0) == 10, "compose(filter, col): untouched row 0")
assert(get(df9_transformed.y, 1) == 120, "compose(filter, col): row 1 + 100")
assert(get(df9_transformed.y, 2) == 130, "compose(filter, col): row 2 + 100")

-- 1h. modify with 3 lenses on same DataFrame
df10 = to_dataframe([[a: 1, b: 2, c: 3]])
la = col_lens("a")
lb = col_lens("b")
lc = col_lens("c")
df10_mod = modify(df10, la, \(x) x .+ 10, lb, \(x) x .* 2, lc, \(x) x .- 1)
assert(get(df10_mod.a, 0) == 11, "modify 3 lenses: a + 10")
assert(get(df10_mod.b, 0) == 4, "modify 3 lenses: b * 2")
assert(get(df10_mod.c, 0) == 2, "modify 3 lenses: c - 1")

print("  Section 1 passed")

-- ============================================================
-- Section 2: Nested Data Deep Traversal
-- ============================================================

print("=== Section 2: Nested Data Deep Traversal ===")

-- 2a. 6-level deep compose(col_lens, ...)
deep = [l1: [l2: [l3: [l4: [l5: [l6: 42]]]]]]
deep_l = compose(col_lens("l1"), col_lens("l2"), col_lens("l3"), col_lens("l4"), col_lens("l5"), col_lens("l6"))
assert(get(deep, deep_l) == 42, "6-level compose get")
deep2 = set(deep, deep_l, 99)
assert(get(deep2, deep_l) == 99, "6-level compose set")
deep3 = over(deep, deep_l, \(x) x + 1)
assert(get(deep3, deep_l) == 43, "6-level compose over")

-- 2b. compose(idx_lens, col_lens) — List of Dicts
items = [[name: "first", val: 10], [name: "second", val: 20], [name: "third", val: 30]]
second_val_l = compose(idx_lens(1), col_lens("val"))
assert(get(items, second_val_l) == 20, "compose(idx, col) get")
items2 = set(items, second_val_l, 999)
assert(get(items2, second_val_l) == 999, "compose(idx, col) set")
items3 = over(items, second_val_l, \(v) v * 3)
assert(get(items3, second_val_l) == 60, "compose(idx, col) over")

-- 2c. compose(col_lens, idx_lens, col_lens) — nested structure
nested = [users: [[scores: [10, 20]], [scores: [30, 40]]]]
second_user_first_score = compose(col_lens("users"), idx_lens(1), col_lens("scores"), idx_lens(0))
assert(get(nested, second_user_first_score) == 30, "3-level compose get")
nested2 = set(nested, second_user_first_score, 999)
assert(get(nested2, second_user_first_score) == 999, "3-level compose set")

-- 2d. col_lens recursive mapping on List of Dicts
data_list = [[v: 1], [v: 2], [v: 3]]
v_l = col_lens("v")
data_list2 = over(data_list, v_l, \(x) x .+ 100)
assert(get(data_list2, 0).v == 101, "col_lens recursive: item 0")
assert(get(data_list2, 1).v == 102, "col_lens recursive: item 1")
assert(get(data_list2, 2).v == 103, "col_lens recursive: item 2")

-- 2e. compose(idx_lens, col_lens) on List of DataFrames
df_a = to_dataframe([[x: 10, y: 20]])
df_b = to_dataframe([[x: 30, y: 40]])
df_list = [df_a, df_b]
second_df_x_l = compose(idx_lens(1), col_lens("x"))
assert(get(get(df_list, second_df_x_l), 0) == 30, "compose(idx, col) on DF list")

print("  Section 2 passed")

-- ============================================================
-- Section 3: Pipeline Lens Operations (the fixes under test)
-- ============================================================

print("=== Section 3: Pipeline Lens Operations ===")

-- 3a. Create and build a pipeline with multiple nodes
p = pipeline {
    alpha = 10
    beta = 20
    gamma = 30
    greeting = "hello"
    sum_node = alpha + beta
}

build_pipeline(p, verbose=0)

-- 3b. read_node on built pipeline
alpha_val = read_node(p.alpha)
assert(alpha_val == 10, "read_node alpha")
sum_val = read_node(p.sum_node)
assert(sum_val == 30, "read_node sum_node (10 + 20)")

-- 3c. NodeLens set existing node → read_node verifies
p2 = set(p, node_lens("alpha"), 42)
build_pipeline(p2, verbose=0)
assert(read_node(p2.alpha) == 42, "node_lens set existing: read_node")

-- 3d. Pipeline immutability: original unchanged after set
assert(read_node(p.alpha) == 10, "pipeline immutability: original alpha unchanged")
assert(read_node(p2.alpha) == 42, "pipeline immutability: new pipeline alpha = 42")

-- 3e. NodeLens set new node (append) → read_node verifies
p3 = set(p, node_lens("delta"), 999)
build_pipeline(p3, verbose=0)
assert(read_node(p3.delta) == 999, "node_lens set new node: read_node")

-- 3f. NodeLens get on missing node returns NA
na_check = get(p, node_lens("nonexistent"))
assert(is_na(na_check) == true, "node_lens get missing node returns NA")

-- 3g. NodeMetaLens get runtime
rt = get(p, node_meta_lens("alpha", "runtime"))
assert(rt == "T", "node_meta_lens get runtime")

-- 3h. NodeMetaLens set noop
p_noop = set(p, node_meta_lens("alpha", "noop"), true)
assert(get(p_noop, node_meta_lens("alpha", "noop")) == true, "node_meta_lens set noop")

-- 3i. NodeMetaLens set/get serializer
p_ser = set(p, node_meta_lens("beta", "serializer"), ^json)
assert(type(get(p_ser, node_meta_lens("beta", "serializer"))) == "Expression", "node_meta_lens set/get serializer")

-- 3j. EnvVarLens set/get roundtrip
p_env = pipeline {
    runner = node(command = <{ 1 + 1 }>, runtime = T)
}
build_pipeline(p_env, verbose=0)
env_l = env_var_lens("runner", "MY_VAR")
p_env2 = set(p_env, env_l, "stressed")
assert(get(p_env2, env_l) == "stressed", "env_var_lens set/get roundtrip")

-- 3k. filter_lens on Pipeline metadata (select by name pattern)
all_nodes_l = filter_lens(\(meta) meta.name == "beta")
matched = get(p, all_nodes_l)
assert(length(matched) == 1, "filter_lens on pipeline: 1 match for beta")

-- 3l. filter_lens set on Pipeline (set matched nodes)
p4 = set(p, filter_lens(\(meta) meta.name == "beta"), 777)
build_pipeline(p4, verbose=0)
assert(read_node(p4.beta) == 777, "filter_lens set on pipeline: beta = 777")

-- 3m. Multiple lens operations chained on same pipeline
p5 = p
    |> set(node_lens("alpha"), 100)
    |> set(node_lens("beta"), 200)
    |> set(node_lens("gamma"), 300)
build_pipeline(p5, verbose=0)
assert(read_node(p5.alpha) == 100, "chained lens: alpha = 100")
assert(read_node(p5.beta) == 200, "chained lens: beta = 200")
assert(read_node(p5.gamma) == 300, "chained lens: gamma = 300")

-- 3n. node_lens set new value → read_node verifies value
p6 = set(p, node_lens("greeting"), "world")
build_pipeline(p6, verbose=0)
assert(read_node(p6.greeting) == "world", "node_lens set greeting: read_node")

print("  Section 3 passed")

-- ============================================================
-- Section 4: Self-Rebind Stress (multiple pipelines in same env)
-- ============================================================

print("=== Section 4: Self-Rebind Stress ===")

p_first = pipeline { x = 1; y = 2 }
p_first2 = set(p_first, node_lens("x"), 10)
build_pipeline(p_first2, verbose=0)
assert(read_node(p_first2.x) == 10, "self-rebind: first pipeline set")

p_second = pipeline { x = 100; y = 200 }
p_second2 = set(p_second, node_lens("y"), 999)
build_pipeline(p_second2, verbose=0)
assert(read_node(p_second2.x) == 100, "self-rebind: second pipeline x intact")
assert(read_node(p_second2.y) == 999, "self-rebind: second pipeline y set")

-- Rebind same variable name
p_rebind = pipeline { a = 1 }
p_rebind2 = set(p_rebind, node_lens("a"), 50)
build_pipeline(p_rebind2, verbose=0)
assert(read_node(p_rebind2.a) == 50, "self-rebind: first binding")

p_rebind := pipeline { a = 2 }
p_rebind2 := set(p_rebind, node_lens("a"), 60)
build_pipeline(p_rebind2, verbose=0)
assert(read_node(p_rebind2.a) == 60, "self-rebind: second binding")

print("  Section 4 passed")

-- ============================================================
-- Section 5: Custom Lenses + Edge Cases
-- ============================================================

print("=== Section 5: Custom Lenses + Edge Cases ===")

-- 5a. Custom Dict-based lens
double_lens = [
    get: \(d) d.x + d.y,
    set: \(d, v) [x: v / 2, y: v / 2]
]
d5 = [x: 10, y: 20]
assert(get(d5, double_lens) == 30, "custom lens get: x + y")
d5_2 = set(d5, double_lens, 100)
assert(d5_2.x == 50, "custom lens set: x = 100/2")
assert(d5_2.y == 50, "custom lens set: y = 100/2")
d5_3 = over(d5, double_lens, \(v) v * 2)
assert(d5_3.x == 30, "custom lens over: x (sum doubled / 2)")
assert(d5_3.y == 30, "custom lens over: y (sum doubled / 2)")

-- 5b. compose(idx_lens, col_lens) on List of Dicts (built-in lens composition)
d5_list = [[x: 10, y: 20], [x: 30, y: 40]]
outer_l = compose(idx_lens(0), col_lens("x"))
assert(get(d5_list, outer_l) == 10, "compose(idx, col) get on list of dicts")

-- 5c. get with default on lens results
d5_missing = [x: 1]
missing_l = col_lens("nonexistent")
assert(get(d5_missing, missing_l, "default_val") == "default_val", "get with default: missing key")
assert(get(d5_missing, col_lens("x"), "default_val") == 1, "get with default: existing key")

-- 5d. col_lens get on missing key returns NA
d5_na = [x: 1]
assert(is_na(get(d5_na, col_lens("missing"))) == true, "col_lens missing key: NA")

print("  Section 5 passed")

-- ============================================================
-- Summary
-- ============================================================

print("")
print("=== lens_stress_test_t: ALL SECTIONS PASSED ===")

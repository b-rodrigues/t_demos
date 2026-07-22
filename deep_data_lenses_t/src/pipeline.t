-- Demo: Surgical updates to nested data using functional lenses.
--
-- Lenses are functional values (VDict with get/set lambdas) and cannot
-- be serialized to disk as pipeline node artifacts. They must be used
-- inline within a single node's command block.

p = pipeline {
  -- 1. Create the base dictionary
  base_data = node(command = [
    owner: "antigravity",
    version: "0.51.2",
    retry: 3,
    tags: ["data", "science", "reproducible"]
  ])

  -- 2. Single-field update using col_lens + over
  updated_version = node(command = {
    l = col_lens("version")
    over(base_data, l, \(v) str_join([v, "-released"], sep = ""))
  })

  -- 3. Increment the retry counter using col_lens + over
  updated_retry = node(command = {
    l = col_lens("retry")
    over(updated_version, l, \(x) x + 1)
  })

  -- 4. Apply both updates in a single modify() pass
  both_updated = node(command = {
    vl = col_lens("version")
    rl = col_lens("retry")
    modify(base_data,
      vl, \(v) str_join([v, "-released"], sep = ""),
      rl, \(x) x + 1
    )
  })

}

build_pipeline(p, verbose=1)

-- Node correctness assertions
res_base = read_node(p.base_data)
check(is_error(res_base) == false)
check(expect_equal(res_base.value.owner, "antigravity"))

res_v = read_node(p.updated_version)
check(is_error(res_v) == false)
check(expect_equal(res_v.value.version, "0.51.2-released"))

res_r = read_node(p.updated_retry)
check(is_error(res_r) == false)
check(expect_equal(res_r.value.retry, 4))

res_b = read_node(p.both_updated)
check(is_error(res_b) == false)
check(expect_equal(res_b.value.version, "0.51.2-released"))
check(expect_equal(res_b.value.retry, 4))

print("✓ deep_data_lenses_t: all assertions passed")

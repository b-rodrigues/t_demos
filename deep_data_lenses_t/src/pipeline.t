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
assert(type(res_base.error) == "NA", "base_data should succeed")
assert(res_base.value.owner == "antigravity", "base_data owner should be 'antigravity'")

res_v = read_node(p.updated_version)
assert(type(res_v.error) == "NA", "updated_version should succeed")
assert(res_v.value.version == "0.51.2-released", "version field should be updated via lens")

res_r = read_node(p.updated_retry)
assert(type(res_r.error) == "NA", "updated_retry should succeed")
assert(res_r.value.retry == 4, "retry should be incremented to 4 via lens")

res_b = read_node(p.both_updated)
assert(type(res_b.error) == "NA", "both_updated should succeed")
assert(res_b.value.version == "0.51.2-released", "both_updated version should be updated via modify()")
assert(res_b.value.retry == 4, "both_updated retry should be incremented via modify()")

print("✓ deep_data_lenses_t: all assertions passed")

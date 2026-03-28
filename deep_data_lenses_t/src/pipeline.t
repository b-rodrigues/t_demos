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

  -- 5. Read back the version field to verify
  final_version = node(command = both_updated.version)
}

build_pipeline(p)

-- Demo: Surgical updates to nested data using functional lenses.

p = pipeline {
  -- 1. Create a deeply nested dictionary structure
  nested_data = node(command = [
    owner: "antigravity",
    version: "0.51.2",
    retry: 3,
    tags: ["data", "science", "reproducible"]
  ])

  -- 2. Use col_lens to surgically update fields
  version_lens = node(command = col_lens("version"))
  retry_lens   = node(command = col_lens("retry"))

  -- 3. Use 'over' to transform specific fields without touching the rest
  updated_version = node(command = over(nested_data, version_lens, \(v) str_join([v, "-released"], sep = "")))

  updated_retry = node(command = over(updated_version, retry_lens, \(x) x + 1))

  -- 4. Use 'modify' to apply multiple lens updates in a single pass
  -- modify(data, lens1, fn1, lens2, fn2, ...)
  both_updated = node(command = modify(
    nested_data,
    version_lens, \(v) str_join([v, "-released"], sep = ""),
    retry_lens,   \(x) x + 1
  ))

  -- 5. Verify the final version by reading a specific field
  final_version = node(command = both_updated.version)
}

build_pipeline(p)

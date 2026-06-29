-- per_node_flake_t: demonstrate per-node flake support in T pipelines
-- with selective fallback for partial flakes (e.g. R-only, no t-lang)

p = pipeline {

  -- Node using the default project flake (current behavior, unchanged)
  a = node(
    command = sum([1, 2, 3, 4, 5]),
    runtime = T
  )

  -- Node using github:b-rodrigues/tlang (full t-lang flake)
  b = node(
    command = length([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
    runtime = T,
    flake = "github:b-rodrigues/tlang"
  )

  -- Node using github:jbedo/rshells (R-only flake, no t-lang packages).
  -- Demonstrates selective fallback: R packages + nixpkgs from custom flake,
  -- T serialization infrastructure from project.
  c = rn(
    command = <{ mean(mtcars$mpg) }>,
    serializer = ^json,
    deserializer = ^json,
    flake = "github:jbedo/rshells"
  )

  -- Node using local path flake (path:../test_flake)
  d = node(
    command = map(\(x) x * 2, [1, 2, 3]),
    runtime = T,
    flake = "path:test_flake"
  )
}

-- Build and execute the pipeline
populate_pipeline(p, build = true)

-- Read back and verify computed results
result = "ok"

res_a = read_node(p.a)
result = if (is_error(res_a)) then error("Node a failed") else result

res_b = read_node(p.b)
result = if (is_error(res_b)) then error("Node b failed") else result

res_c = read_node(p.c)
result = if (is_error(res_c)) then error("Node c failed") else result

res_d = read_node(p.d)
result = if (is_error(res_d)) then error("Node d failed") else result

result

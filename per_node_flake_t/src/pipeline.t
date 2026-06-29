-- per_node_flake_t: demonstrate per-node flake support in T pipelines
-- with selective fallback for partial flakes (e.g. R-only, no t-lang)

p = pipeline {

  -- Node using the default project flake (current behavior, unchanged)
  a = node(
    command = "sum([1, 2, 3, 4, 5])",
    runtime = T
  )

  -- Node using github:b-rodrigues/tlang (full t-lang flake)
  b = node(
    command = "length([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])",
    runtime = T,
    flake = "github:b-rodrigues/tlang"
  )

  -- Node using github:jbedo/rshells (R-only flake, no t-lang packages).
  -- Demonstrates selective fallback: R packages + nixpkgs from custom flake,
  -- T serialization infrastructure from project.
  c = rn(
    command = "mean(mtcars$mpg)",
    serializer = "json",
    deserializer = "json",
    flake = "github:jbedo/rshells"
  )

  -- Node using local path flake (path:../test_flake)
  d = node(
    command = "map(x -> x * 2, [1, 2, 3])",
    runtime = T,
    flake = "path:../test_flake"
  )
}

-- Build and execute the pipeline
populate_pipeline(p, build = true)

-- Read generated Nix template for verification
nix = read_file("_pipeline/pipeline.nix")

-- Verify mkNodeEnv exists
assert(contains(nix, "mkNodeEnv"), "Generated Nix should define mkNodeEnv function")

-- Verify per-flake env bindings exist for all custom flakes
assert(contains(nix, "env_github_b_rodrigues_tlang"),
       "Nix should contain env binding for github:b-rodrigues/tlang")
assert(contains(nix, "env_github_jbedo_rshells"),
       "Nix should contain env binding for github:jbedo/rshells")
assert(contains(nix, "env_path_test_flake"),
       "Nix should contain env binding for local path flake (path:../test_flake)")

-- Verify selective fallback patterns exist in the Nix template
assert(contains(nix, "if tlangPkgSet ? default then"),
       "Nix should contain selective fallback for tBin (via ? operator)")
assert(contains(nix, "if tlangPkgSet ? tlang-r then"),
       "Nix should contain selective fallback for r-env (via ? operator)")
assert(contains(nix, "if tlangPkgSet ? tlang-julia-path then"),
       "Nix should contain selective fallback for tlangJl (via ? operator)")

-- Verify backward compat: project-level bindings still exist
assert(contains(nix, "stdenv = projectStdenv"), "Nix should alias stdenv to projectStdenv")
assert(contains(nix, "tBin   = projectTBin"), "Nix should alias tBin to projectTBin")
assert(contains(nix, "projectFlake"), "Nix should contain project-level flake binding")

-- Read back and verify computed results
res_a = read_node(p.a)
assert(res_a == 15, "Node a: sum([1..5]) should equal 15")

res_b = read_node(p.b)
assert(res_b == 10, "Node b: length([1..10]) should equal 10")

res_c = read_node(p.c)
assert(abs(res_c - 20.09062) < 0.001,
       "Node c: mean(mtcars$mpg) should equal 20.09")

res_d = read_node(p.d)
assert(res_d == [2, 4, 6], "Node d: map(x -> x * 2, [1, 2, 3]) should equal [2, 4, 6]")

print("✓ per_node_flake_t: all assertions passed")

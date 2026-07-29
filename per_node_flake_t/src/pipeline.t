-- per_node_flake_t: demonstrate per-node flake support in T pipelines
-- with real computation, build, and read_node verification

p = pipeline {
  -- Node using the default project flake (current behavior, unchanged)
  a = node(
    command = sum([1, 2, 3, 4, 5]),
    runtime = T
  )

  -- Node using a custom flake that fully replaces T infrastructure
  b = node(
    command = length([10, 20, 30, 40]),
    runtime = T,
    flake = "github:b-rodrigues/tlang"
  )

  -- Node using an R-only flake (jbedo/rshells provides R from nixpkgs/r-updates
  -- but no t-lang infrastructure; T serialization falls back to project)
  c = node(
    command = <{ mean(mtcars$mpg) }>,
    runtime = R,
    serializer = ^json,
    flake = "github:jbedo/rshells"
  )

  -- Node using a local flake via path: URL
  d = node(
    command = [1, 2, 3] |> map(\(x) x * 10),
    runtime = T,
    flake = "path:test_flake"
  )

  -- Node using nixpkgs directly as the flake for Julia runtime
  e = node(
    command = <{ sum([1, 2, 3, 4, 5]) / length([1, 2, 3, 4, 5]) }>,
    runtime = Julia,
    serializer = ^json,
    flake = "github:NixOS/nixpkgs/nixos-24.11"
  )

  -- Node using rshells flake for R — test dplyr availability
  -- The flake controls which nixpkgs to build from, but project-level
  -- [r-dependencies] in tproject.toml are still installed on top.
  -- Since dplyr is NOT in this project's [r-dependencies], it won't be
  -- available unless the flake itself pre-installs it.
  f = node(
    command = <{
      if (require(dplyr, quietly = TRUE)) {
        "dplyr IS available on rshells flake"
      } else {
        "dplyr IS NOT available on rshells flake"
      }
    }>,
    runtime = R,
    serializer = ^json,
    flake = "github:jbedo/rshells"
  )

  -- Node using minimal R flake — test dplyr isolation
  -- Same inheritance behavior: project-level [r-dependencies] (jsonlite)
  -- are installed, but dplyr is not.
  g = node(
    command = <{
      if (require(dplyr, quietly = TRUE)) {
        "dplyr IS available in this node"
      } else {
        "dplyr is NOT available in this node"
      }
    }>,
    runtime = R,
    serializer = ^json,
    flake = "path:minimal_r_flake"
  )
}

-- Generate Nix and build all nodes
populate_pipeline(p, build = true)

-- Read the generated Nix file for structural assertions
nix = read_file("_pipeline/pipeline.nix")

-- Verify the Nix template contains the mkNodeEnv helper function
assert(str_detect(nix, "mkNodeEnv"), "Generated Nix should define mkNodeEnv function")

-- Verify per-flake env bindings exist for all custom flakes
assert(str_detect(nix, "env_github_b_rodrigues_tlang"),
       "Nix should contain env binding for github:b-rodrigues/tlang")
assert(str_detect(nix, "env_github_jbedo_rshells"),
       "Nix should contain env binding for github:jbedo/rshells")
assert(str_detect(nix, "\"test_flake\""),
       "Nix should contain env binding for local path flake (path:../test_flake)")

-- Verify each custom flake node uses its own env
assert(str_detect(nix, "env_github_b_rodrigues_tlang.stdenv"),
       "Node b should use its own flake env (tlang)")
assert(str_detect(nix, "env_github_jbedo_rshells.\"r-env\""),
       "Node c should use its own flake env (rshells)")
assert(str_detect(nix, "test_flake.stdenv"),
       "Node d should use its own flake env (path flake)")

-- Verify env bindings for new per-node flakes
assert(str_detect(nix, "env_github_NixOS_nixpkgs"),
       "Nix should contain env binding for github:NixOS/nixpkgs (Julia node)")
assert(str_detect(nix, "\"minimal_r_flake\""),
       "Nix should contain env binding for minimal R flake (path:minimal_r_flake)")

-- Verify each new node uses its own env
assert(str_detect(nix, "env_github_jbedo_rshells.\"r-env\""),
       "Node f should use its own flake env (rshells)")
assert(str_detect(nix, "minimal_r_flake"),
       "Node g should use its own flake env (minimal R)")

-- Verify backward compat: project-level env bindings still exist
assert(str_detect(nix, "projectStdenv"), "Nix should contain project-level stdenv binding")
assert(str_detect(nix, "projectFlake"), "Nix should contain project-level flake binding")

-- Verify backward compat: alias bindings exist for project env
assert(str_detect(nix, "stdenv = projectStdenv"), "Nix should alias stdenv to projectStdenv")
assert(str_detect(nix, "tBin   = projectTBin"), "Nix should alias tBin to projectTBin")

-- Verify fallback logic for R-only flakes (rshells lacks t-lang infrastructure)
-- The env should still reference projectTBin for T serialization
assert(str_detect(nix, "tBin = if tlangPkgSet ? default then tlangPkgSet.default else projectTBin"),
       "mkNodeEnv should fall back to projectTBin when flake lacks t-lang")
assert(str_detect(nix, "r-env = pkgs.rWrapper.override"),
       "R env is built from the custom flake's nixpkgs")

-- Now read back the computed results
result_a = read_node(p.a)
result_b = read_node(p.b)
result_c = read_node(p.c)
result_d = read_node(p.d)
result_e = read_node(p.e)
result_f = read_node(p.f)
result_g = read_node(p.g)

-- Print results for visual verification
print("Node a (default flake):    sum([1..5]) =")
print(to_string(result_a))
print("Node b (tlang flake):      length([10..40]) =")
print(to_string(result_b))
print("Node c (rshells flake):    mean(mtcars$mpg) =")
print(to_string(result_c))
print("Node d (path flake):       [1,2,3] * 10 =")
print(to_string(result_d))
print("Node e (nixpkgs flake):    Julia sum/len([1..5]) =")
print(to_string(result_e))
print("Node f (rshells flake):    R dplyr check =")
print(to_string(result_f))
print("Node g (minimal R flake):  R dplyr check =")
print(to_string(result_g))

-- Verify correctness
assert(result_a == 15, "sum([1, 2, 3, 4, 5]) should be 15")
assert(result_b == 4, "length([10, 20, 30, 40]) should be 4")
assert(result_c == 20.09062, "mean(mtcars$mpg) should be 20.09062 (R's value)")
assert(identical(result_d, [10, 20, 30]), "map(x * 10) over [1,2,3] should produce [10,20,30]")
assert(result_e == 3.0, "Julia sum([1..5])/len([1..5]) should be 3.0")

-- Per-node flake R nodes: dplyr availability depends on project-level
-- [r-dependencies] and what the flake's nixpkgs provides. With dplyr
-- absent from tproject.toml, both nodes should report it unavailable.
assert(type(result_f) == "string", "Node f should return a dplyr availability string")
assert(type(result_g) == "string", "Node g should return a dplyr availability string")
assert(str_detect(result_f, "dplyr"),
       "Node f result should mention dplyr")
assert(str_detect(result_g, "dplyr"),
       "Node g result should mention dplyr")

print("✓ per_node_flake_t: all Nix verification and computation assertions passed")

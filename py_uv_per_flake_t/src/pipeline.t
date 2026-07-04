-- py_uv_per_flake_t: combine UV workspace Python resolver with per-node custom flakes
-- Verifies that per-flake infrastructure and UV workspace Python environments
-- compose correctly for multi-language pipelines

p = pipeline {
  a = node(
    command = <{
      import pandas as pd
      df = pd.read_csv("data/scores.csv")
      float(df["score"].mean())
    }>,
    runtime = Python
  ),

  b = node(
    command = sum([1, 2, 3, 4, 5]),
    runtime = T
  ),

  c = node(
    command = <{ mean(mtcars$mpg) }>,
    runtime = R,
    serializer = ^json,
    flake = "github:jbedo/rshells"
  ),

  d = node(
    command = <{ sum([1, 2, 3, 4, 5]) / length([1, 2, 3, 4, 5]) }>,
    runtime = Julia,
    serializer = ^json,
    flake = "github:NixOS/nixpkgs/nixos-24.11"
  ),

  e = node(
    command = <{
      import pandas as pd
      df = pd.read_csv("data/scores.csv")
      float(df["score"].mean())
    }>,
    runtime = Python,
    flake = "github:NixOS/nixpkgs/nixos-24.11"
  )
}

populate_pipeline(p, build = true)

nix = read_file("_pipeline/pipeline.nix")

-- mkNodeEnv is the core of per-flake infrastructure
assert(contains(nix, "mkNodeEnv"),
       "Generated Nix should define mkNodeEnv function")

-- pyResolver and mkVirtualEnv are the core of UV workspace support
assert(contains(nix, "pyResolver"),
       "Generated Nix should reference pyResolver (UV workspace)")
assert(contains(nix, "mkVirtualEnv"),
       "Generated Nix should use mkVirtualEnv for UV workspace env")

-- Per-flake env bindings for custom flakes
assert(contains(nix, "env_github_jbedo_rshells"),
       "Nix should contain env binding for github:jbedo/rshells")
assert(contains(nix, "env_github_NixOS_nixpkgs"),
       "Nix should contain env binding for github:NixOS/nixpkgs")

-- Custom flake nodes use their own env
assert(contains(nix, "env_github_jbedo_rshells.\"r-env\""),
       "Node c should use rshells flake's r-env")
assert(contains(nix, "env_github_NixOS_nixpkgs.\"jl-env\""),
       "Node d should use nixpkgs flake's jl-env")

-- Project-level py-env exists for UV workspace
assert(contains(nix, "projectPyEnv"),
       "Generated Nix should contain project-level py-env binding")

-- Project-level env bindings (backward compat)
assert(contains(nix, "projectStdenv"), "Nix should contain project-level stdenv binding")
assert(contains(nix, "projectFlake"), "Nix should contain project-level flake binding")

-- Fallback logic for flakes without t-lang infrastructure
assert(contains(nix, "tBin = if tlangPkgSet ? default then tlangPkgSet.default else projectTBin"),
       "mkNodeEnv should fall back to projectTBin when flake lacks t-lang")

-- Read back computed results
result_a = read_node(p.a)
result_b = read_node(p.b)
result_c = read_node(p.c)
result_d = read_node(p.d)
result_e = read_node(p.e)

-- Verify correctness
assert(result_a == 87.8,
       "mean of score column should be 87.8 (UV workspace Python)")
assert(result_b == 15,
       "sum([1, 2, 3, 4, 5]) should be 15")
assert(result_c == 20.09062,
       "mean(mtcars$mpg) should be 20.09062 (R via rshells flake)")
assert(result_d == 3.0,
       "Julia sum/len([1..5]) should be 3.0")
assert(result_e == 87.8,
       "mean of score column should be 87.8 (Python + custom flake + UV workspace)")

print("✓ py_uv_per_flake_t: all Nix verification and computation assertions passed")

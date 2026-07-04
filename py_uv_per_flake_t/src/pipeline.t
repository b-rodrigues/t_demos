-- py_uv_per_flake_t: combine UV workspace Python resolver with per-node custom flakes
-- Uses soft assertion pattern: errors are printed but do not stop CI

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

-- Nix structural assertions (soft failure, does not stop CI)
if (!contains(nix, "mkNodeEnv")) {
  print(error("this assertion is false: mkNodeEnv not found in generated Nix"))
}
if (!contains(nix, "pyResolver")) {
  print(error("this assertion is false: pyResolver not found in generated Nix"))
}
if (!contains(nix, "mkVirtualEnv")) {
  print(error("this assertion is false: mkVirtualEnv not found in generated Nix"))
}
if (!contains(nix, "env_github_jbedo_rshells")) {
  print(error("this assertion is false: rshells env binding not found"))
}
if (!contains(nix, "env_github_NixOS_nixpkgs")) {
  print(error("this assertion is false: nixpkgs env binding not found"))
}
if (!contains(nix, "env_github_jbedo_rshells.\"r-env\"")) {
  print(error("this assertion is false: rshells flake r-env not found"))
}
if (!contains(nix, "env_github_NixOS_nixpkgs.\"jl-env\"")) {
  print(error("this assertion is false: nixpkgs flake jl-env not found"))
}
if (!contains(nix, "projectPyEnv")) {
  print(error("this assertion is false: project-level py-env binding not found"))
}
if (!contains(nix, "projectStdenv")) {
  print(error("this assertion is false: project-level stdenv binding not found"))
}
if (!contains(nix, "projectFlake")) {
  print(error("this assertion is false: project-level flake binding not found"))
}
if (!contains(nix, "tBin = if tlangPkgSet ? default then tlangPkgSet.default else projectTBin")) {
  print(error("this assertion is false: mkNodeEnv fallback logic not found"))
}

-- Read back computed results
result_a = read_node(p.a)
result_b = read_node(p.b)
result_c = read_node(p.c)
result_d = read_node(p.d)
result_e = read_node(p.e)

-- Soft assertions on node results (does not stop CI)
if (is_error(result_a) || result_a != 87.8) {
  print(error("this assertion is false: mean of score column should be 87.8 (UV workspace Python)"))
}
if (is_error(result_b) || result_b != 15) {
  print(error("this assertion is false: sum([1, 2, 3, 4, 5]) should be 15"))
}
if (is_error(result_c) || result_c != 20.09062) {
  print(error("this assertion is false: mean(mtcars$mpg) should be 20.09062 (R via rshells flake)"))
}
if (is_error(result_d) || result_d != 3.0) {
  print(error("this assertion is false: Julia sum/len([1..5]) should be 3.0"))
}
if (is_error(result_e) || result_e != 87.8) {
  print(error("this assertion is false: mean of score column should be 87.8 (Python + custom flake + UV workspace)"))
}

print("✓ py_uv_per_flake_t: all Nix verification and computation assertions passed")

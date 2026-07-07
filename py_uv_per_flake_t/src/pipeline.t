-- py_uv_per_flake_t: combine UV workspace Python resolver with per-node custom flakes
-- Uses soft assertion pattern: errors are printed but do not stop CI

p = pipeline {
  a = node(
    command = <{
      import pandas as pd
      df = pd.read_csv("data/scores.csv")
      float(df["score"].mean())
    }>,
    runtime = Python,
    serializer = ^json
  )

  b = node(
    command = sum([1, 2, 3, 4, 5]),
    runtime = T
  )

  c = node(
    command = <{ mean(mtcars$mpg) }>,
    runtime = R,
    serializer = ^json,
    flake = "github:jbedo/rshells"
  )

  d = node(
    command = <{ sum([1, 2, 3, 4, 5]) / length([1, 2, 3, 4, 5]) }>,
    runtime = Julia,
    serializer = ^json,
    flake = "github:NixOS/nixpkgs/nixos-24.11"
  )

  e = node(
    command = <{
      import numpy as np
      float(np.array([1, 2, 3, 4, 5]).sum())
    }>,
    runtime = Python,
    serializer = ^json,
    flake = "path:./flake-e"
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
if (!contains(nix, "env_github_nixos_nixpkgs_nixos_24_11")) {
  print(error("this assertion is false: nixpkgs env binding not found"))
}
if (!contains(nix, "env_path") || !contains(nix, "flake_e")) {
  print(error("this assertion is false: flake-e path-based env binding not found"))
}
if (!contains(nix, "env_github_jbedo_rshells.r-env")) {
  print(error("this assertion is false: rshells flake r-env not found"))
}
if (!contains(nix, "env_github_nixos_nixpkgs_nixos_24_11.juliaPkg")) {
  print(error("this assertion is false: nixpkgs flake juliaPkg not found"))
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
if (!contains(nix, "tBin   = if tlangPkgSet ? default then tlangPkgSet.default else projectTBin;")) {
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
if (is_error(result_c) || result_c != 20.090625) {
  print(error("this assertion is false: mean(mtcars$mpg) should be 20.090625 (R via rshells flake)"))
}
if (is_error(result_d) || result_d != 3.0) {
  print(error("this assertion is false: Julia sum/len([1..5]) should be 3.0"))
}
if (is_error(result_e) || result_e != 15.0) {
  print(error("this assertion is false: np.array([1,2,3,4,5]).sum() should be 15.0 (Python + flake-e custom numpy env)"))
}

print("✓ py_uv_per_flake_t: all Nix verification and computation assertions passed")

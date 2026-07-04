-- everything_t: comprehensive demo testing renv, uv, per-node flakes, and R git auto-detection
-- Each node demonstrates something only its specific resolver/flake setup can provide

p = pipeline {

  -- R + renv.lock: datathin is resolved from renv.lock (GitHub via renv)
  datathin = node(
    command = <{
      cat("--- R/renv: datathin::datathin() ---\n")
      library(datathin)
      set.seed(42)
      x = rnorm(100)
      result = datathin(x, family = "normal", K = 2, arg = 1)
      cat(sprintf("Only possible because renv.lock resolved datathin from GitHub and its CRAN deps (VGAM, extraDistr, mvtnorm)\n"))
      cat(sprintf("Data thinning split 100 observations into %d total outputs (training + test)\n", length(unlist(result))))
      length(unlist(result))
    }>,
    runtime = R,
    serializer = ^json
  )

  -- R + git auto-detect: brotools deps resolved from DESCRIPTION/NAMESPACE
  modecomp = node(
    command = <{
      cat("--- R/git: brotools::sample_mode() via DESCRIPTION auto-detection ---\n")
      library(brotools)
      data = c(7, 7, 7, 1, 2, 3)
      m = sample_mode(data)
      cat(sprintf("Only possible because DESCRIPTION auto-detection resolved all 12 CRAN deps (dplyr, rlang, stringr, ...)\n"))
      cat(sprintf("Mode of c(7,7,7,1,2,3) is %d (not available in base R)\n", m))
      m
    }>,
    runtime = R,
    serializer = ^json
  )

  -- Python + uv workspace: pandas from uv.lock, not nixpkgs withPackages
  py_mean = node(
    command = <{
      import pandas as pd
      print("--- Python/uv: pandas from uv workspace ---")
      df = pd.read_csv("data/scores.csv")
      m = float(df["score"].mean())
      print("Only possible because uv workspace resolver provides pandas via pyproject.toml + uv.lock")
      print(f"Mean score from scores.csv: {m}")
      m
    }>,
    runtime = Python,
    serializer = ^json
  )

  -- Julia + per-node flake: uses nixos-24.11 (different nixpkgs than project default rstats-on-nix)
  jl_custom = node(
    command = <{
      println("--- Julia/custom flake: nixos-24.11 ---")
      result = "This Julia node runs from nixos-24.11 nixpkgs, not the project default rstats-on-nix"
      println("Only possible because per-node flake support lets this node use a different nixpkgs")
      println(result)
      result
    }>,
    runtime = Julia,
    flake = "github:NixOS/nixpkgs/nixos-24.11"
  )

}

populate_pipeline(p, build = true)

-- Read results
r_datathin = read_node(p.datathin)
r_modecomp = read_node(p.modecomp)
r_py_mean = read_node(p.py_mean)
r_jl_custom = read_node(p.jl_custom)

-- Verify renv-resolved datathin works
if (is_error(r_datathin)) {
  print(error("R/renv: datathin node failed - check renv.lock resolution"))
} else {
  assert(r_datathin == 200, str_join(["datathin(rnorm(100), K=2) gave ", to_string(r_datathin), " expected 200"]))
  print(str_join(["✓ R/renv: datathin produced ", to_string(r_datathin), " thinned outputs"]))
}

-- Verify git auto-detected brotools works
if (is_error(r_modecomp)) {
  print(error("R/git: brotools node failed - check DESCRIPTION auto-detection"))
} else {
  assert(r_modecomp == 7, str_join(["mode should be 7, got ", to_string(r_modecomp)]))
  print("✓ R/git: brotools::sample_mode() = 7")
}

-- Verify uv workspace pandas works
if (is_error(r_py_mean)) {
  print(error("Python/uv: pandas node failed - check uv workspace resolver"))
} else {
  assert(r_py_mean == 87.8, str_join(["mean score should be 87.8, got ", to_string(r_py_mean)]))
  print(str_join(["✓ Python/uv: mean score = ", to_string(r_py_mean)]))
}

-- Verify per-node flake Julia works
if (is_error(r_jl_custom)) {
  print(error("Julia/custom flake: node failed - check per-node flake support"))
} else {
  print("✓ Julia/custom flake: node from nixos-24.11 succeeded")
}

print("✓ everything_t: all four resolvers and features working together")

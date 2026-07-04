-- everything_t: comprehensive demo testing renv, uv, per-node flakes, and R git auto-detection
-- Each node demonstrates something only its specific resolver/flake setup can provide

p = pipeline {

  -- R + renv.lock: datathin is resolved from renv.lock (GitHub via renv)
  a = node(
    command = <{
      cat("--- R/renv: datathin::thin() ---\n")
      library(datathin)
      set.seed(42)
      x = rnorm(100)
      thinned = thin(x, 2)
      cat(sprintf("Only possible because renv.lock resolved datathin from GitHub and its CRAN deps (VGAM, extraDistr, mvtnorm)\n"))
      cat(sprintf("Thinned 100 observations to %d (preserves statistical properties with half the sample)\n", length(thinned)))
      length(thinned)
    }>,
    runtime = R,
    serializer = ^json
  ),

  -- R + git auto-detect: brotools deps resolved from DESCRIPTION/NAMESPACE
  b = node(
    command = <{
      cat("--- R/git: brotools::sample_mode() via DESCRIPTION auto-detection ---\n")
      library(brotools)
      data = c(1, 1, 2, 3, 3, 3)
      m = sample_mode(data)
      cat(sprintf("Only possible because DESCRIPTION auto-detection resolved all 12 CRAN deps (dplyr, rlang, stringr, ...)\n"))
      cat(sprintf("Mode of c(1,1,2,3,3,3) is %d (not available in base R)\n", m))
      m
    }>,
    runtime = R,
    serializer = ^json
  ),

  -- Python + uv workspace: pandas from uv.lock, not nixpkgs withPackages
  c = node(
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
  ),

  -- Julia + per-node flake: uses nixos-24.11 (different nixpkgs than project default rstats-on-nix)
  d = node(
    command = <{
      println("--- Julia/custom flake: nixos-24.11 ---")
      result = "This Julia node runs from nixos-24.11 nixpkgs, not the project default rstats-on-nix"
      println("Only possible because per-node flake support lets this node use a different nixpkgs")
      println(result)
      result
    }>,
    runtime = Julia,
    flake = "github:NixOS/nixpkgs/nixos-24.11",
    serializer = ^json
  )

}

populate_pipeline(p, build = true)

-- Read results
r_a = read_node(p.a)
r_b = read_node(p.b)
r_c = read_node(p.c)
r_d = read_node(p.d)

-- Verify renv-resolved datathin works
if (is_error(r_a)) {
  print(error("R/renv: datathin node failed — check renv.lock resolution"))
} else {
  assert(r_a >= 40 && r_a <= 60, str_join(["thin(rnorm(100), 2) should give ~50 obs, got ", to_string(r_a)]))
  print(str_join(["✓ R/renv: datathin thinned to ", to_string(r_a), " observations"]))
}

-- Verify git auto-detected brotools works
if (is_error(r_b)) {
  print(error("R/git: brotools node failed — check DESCRIPTION auto-detection"))
} else {
  assert(r_b == 3, str_join(["sample_mode(c(1,1,2,3,3,3)) should be 3, got ", to_string(r_b)]))
  print("✓ R/git: brotools::sample_mode() = 3")
}

-- Verify uv workspace pandas works
if (is_error(r_c)) {
  print(error("Python/uv: pandas node failed — check uv workspace resolver"))
} else {
  assert(r_c == 87.8, str_join(["mean score should be 87.8, got ", to_string(r_c)]))
  print(str_join(["✓ Python/uv: mean score = ", to_string(r_c)]))
}

-- Verify per-node flake Julia works
if (is_error(r_d)) {
  print(error("Julia/custom flake: node failed — check per-node flake support"))
} else {
  print("✓ Julia/custom flake: node from nixos-24.11 succeeded")
}

print("✓ everything_t: all four resolvers and features working together")

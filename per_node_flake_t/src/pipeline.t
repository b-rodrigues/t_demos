-- per_node_flake_t: demonstrate per-node flake support in T pipelines

p = pipeline {
  -- Node using the default project flake (current behavior, unchanged)
  a = node(
    command = "hello from default flake",
    runtime = T
  )

  -- Node using a custom flake
  b = node(
    command = "hello from custom flake (tlang)",
    runtime = T,
    flake = "github:b-rodrigues/tlang"
  )

  -- Second node using a different custom flake
  c = node(
    command = "hello from custom flake (rix)",
    runtime = T,
    flake = "github:b-rodrigues/rix"
  )

  -- Third node using a local flake via path: URL
  d = node(
    command = "hello from local path flake",
    runtime = T,
    flake = "path:../test_flake"
  )
}

-- Populate to generate the Nix expression without building.
-- This lets us inspect the generated Nix code.
populate_pipeline(p, build = false)

-- Read the generated Nix file
nix = read_file("_pipeline/pipeline.nix")

-- Verify the Nix template contains the mkNodeEnv helper function
assert(contains(nix, "mkNodeEnv"), "Generated Nix should define mkNodeEnv function")

-- Verify per-flake env bindings exist for all custom flakes
assert(contains(nix, "env_github_b_rodrigues_tlang"),
       "Nix should contain env binding for github:b-rodrigues/tlang")
assert(contains(nix, "env_github_b_rodrigues_rix"),
       "Nix should contain env binding for github:b-rodrigues/rix")
assert(contains(nix, "env_path_test_flake"),
       "Nix should contain env binding for local path flake (path:../test_flake)")

-- Verify each custom flake node uses its own env
assert(contains(nix, "env_github_b_rodrigues_tlang.stdenv"),
       "Node b should use its own flake env (tlang)")
assert(contains(nix, "env_github_b_rodrigues_rix.stdenv"),
       "Node c should use its own flake env (rix)")
assert(contains(nix, "env_path_test_flake.stdenv"),
       "Node d should use its own flake env (path flake)")

-- Verify backward compat: project-level env bindings still exist
assert(contains(nix, "projectStdenv"), "Nix should contain project-level stdenv binding")
assert(contains(nix, "projectFlake"), "Nix should contain project-level flake binding")

-- Verify backward compat: alias bindings exist for project env
assert(contains(nix, "stdenv = projectStdenv"), "Nix should alias stdenv to projectStdenv")
assert(contains(nix, "tBin   = projectTBin"), "Nix should alias tBin to projectTBin")

print("✓ per_node_flake_t: all Nix verification assertions passed")

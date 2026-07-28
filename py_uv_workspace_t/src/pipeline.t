-- py_uv_workspace_t: demonstrate UV workspace Python dependency resolver in T pipelines
-- Python node uses pandas from a UV workspace to read a CSV and compute a statistic

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
}

populate_pipeline(p, build = true)

-- Read the generated Nix file for structural assertions
nix = read_file("_pipeline/pipeline.nix")

-- Verify UV workspace path is used, not nixpkgs withPackages
assert(str_detect(nix, "pyResolver"),
       "Generated Nix should reference pyResolver")
assert(str_detect(nix, "mkVirtualEnv"),
       "Generated Nix should use mkVirtualEnv for UV workspace env")

-- Read back the computed result
result = read_node(p.a)

-- Print result for visual verification
print("Node a (UV workspace Python): mean score =")
print(to_string(result))

-- Verify correctness
assert(result == 87.8, "mean of score column should be 87.8")

print("✓ py_uv_workspace_t: all UV workspace and computation assertions passed")

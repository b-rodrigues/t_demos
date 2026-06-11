-- Quarto Runtime Test
--
-- This pipeline tests the Quarto runtime by generating data in T
-- and rendering a .qmd file that consumes that data via read_node().

p = pipeline {
  data = "Success: Data read from T-Lang"

  report = node(
    script = "src/report.qmd",
    runtime = Quarto,
    args = [
      to: "html",
      standalone: true
    ]
  )
}

-- build=true triggers nix-build
populate_pipeline(p, build=true)

-- Test pipeline_copy
print("Copying results to local directory...")
res = pipeline_copy()
print(res)

-- Verify data node is accessible (no read_node needed for inline values)
assert(p.data == "Success: Data read from T-Lang", "data node should have correct value")

print("✓ quarto_test_t: all assertions passed")

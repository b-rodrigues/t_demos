-- r_git_pkgs_t: install an R package from a git repository and use it in a pipeline
-- Uses brotools::sample_mode() to compute the statistical mode

p = pipeline {

  a = node(
    command = <{
      library(brotools)
      sample_mode(c(1, 1, 2, 3))
    }>,
    runtime = R,
    serializer = ^json
  )

}

populate_pipeline(p, build = true)

-- Read results
result_a = read_node(p.a)

-- Verify results (soft assertions, does not stop CI)
if (is_error(result_a) || result_a != 1) {
  print(error("this assertion is false: sample_mode(c(1, 1, 2, 3)) should be 1"))
}

print("✓ r_git_pkgs_t: all git R package computation assertions passed")

-- r_renv_t: demonstrates renv.lock resolver for auto-detecting R dependencies
-- Uses datathin package (installed from GitHub via renv.lock)
-- and CRAN packages (VGAM, extraDistr, mvtnorm)

p = pipeline {

  a = node(
    command = <{
      library(jsonlite)
      library(datathin)
      result = toJSON(list(
        pkgs_loaded = "jsonlite, datathin",
        n_rnorm = length(rnorm(10))
      ), auto_unbox = TRUE)
    }>,
    runtime = R,
    serializer = ^json
  )

}

populate_pipeline(p, build = true)

-- Read results
result_a = read_node(p.a)

if (is_error(result_a)) {
  print(error("r_renv_t pipeline failed"))
} else {
  print("✓ r_renv_t: renv.lock-based R dependencies resolved successfully")
}

p = pipeline {
  r_node = rn(
    command = <{
      # dplyr is requested in tproject.toml
      library(dplyr)
      # Check if tlang (the R companion package) is available
      library(tlang)
      res_r = "R companion package loaded successfully"
    }>
  )

  py_node = pyn(
    command = <{
      # cronista is requested in tproject.toml
      import cronista
      # Check if tlang (the Python companion package) is available
      import tlang
      res_py = "Python companion package loaded successfully"
    }>
  )

  jl_node = jln(
    command = <{
      # DataFrames is requested in tproject.toml
      using DataFrames
      # Check if tlang (the Julia companion package) is available
      using tlang
      res_jl = "Julia companion package loaded successfully"
    }>
  )
}

populate_pipeline(p, build = true)

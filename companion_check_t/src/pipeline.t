p = pipeline {
  data_node = rn(
    command = <{
      df <- data.frame(name = c("A", "B", "C"), value = c(10, 20, 30))
      df
    }>,
    serializer = ^csv
  )

  r_node = rn(
    command = <{
      library(tlang)
      "R companion package loaded successfully"
    }>
  )

  py_node = pyn(
    command = <{
      import tlang
      "Python companion package loaded successfully"
    }>
  )

  jl_node = jln(
    command = <{
      using tlang
      "Julia companion package loaded successfully"
    }>
  )
}

populate_pipeline(p, build = true)

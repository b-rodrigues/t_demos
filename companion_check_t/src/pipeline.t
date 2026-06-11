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

-- Node correctness assertions (verify companion packages load)
r_data = read_node(p.data_node)
assert(type(r_data.error) == "NA", "data_node should succeed")

r_r = read_node(p.r_node)
assert(type(r_r.error) == "NA", "r_node (tlang R companion) should succeed")

r_py = read_node(p.py_node)
assert(type(r_py.error) == "NA", "py_node (tlang Python companion) should succeed")

r_jl = read_node(p.jl_node)
assert(type(r_jl.error) == "NA", "jl_node (tlang Julia companion) should succeed")

print("✓ companion_check_t: all assertions passed")

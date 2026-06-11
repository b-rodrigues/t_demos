-- many_inputs_t pipeline mimicking rixpress_demos/many_inputs_example

p = pipeline {
  -- Load multiple CSVs using R
  mtcars_r = rn(
    command = <{
      readr::read_delim(list.files("data", full.names = TRUE), delim = "|")
    }>,
    include = ["data"],
    serializer = ^arrow
  )

  -- Load multiple CSVs using Python
  mtcars_py = pyn(
    command = <{
      read_many_csvs("data")
    }>,
    functions = ["src/functions.py"],
    include = ["data"],
    serializer = ^arrow
  )

  -- Python node taking head of mtcars_py
  -- Mimics rxp_py(name = head_mtcars, expr = "mtcars_py.head()", ...)
  head_mtcars = pyn(
    command = <{ mtcars_py.head() }>,
    deserializer = ^arrow,
    serializer = ^arrow -- Optional
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Node correctness assertions
r_r = read_node(p.mtcars_r)
assert(type(r_r.error) == "NA", "mtcars_r (R loading multiple CSVs) should succeed")

r_py = read_node(p.mtcars_py)
assert(type(r_py.error) == "NA", "mtcars_py (Python loading multiple CSVs) should succeed")

r_head = read_node(p.head_mtcars)
assert(type(r_head.error) == "NA", "head_mtcars should succeed")

print("✓ many_inputs_t: all assertions passed")

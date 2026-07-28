-- basic_t pipeline mimicking rixpress_demos/basic_r

p = pipeline {
  -- Load data
  -- In rixpress: rxp_r_file(name = mtcars, path = 'data/mtcars.csv', read_function = \(x) (read.csv(file = x, sep = "|")))
  mtcars = read_csv("data/mtcars.csv", separator = "|")

  -- Filter transformation
  -- In rixpress: rxp_r(name = filtered_mtcars, expr = dplyr::filter(mtcars, am == 1))
  filtered_mtcars = mtcars |> filter($am == 1)

  -- Select transformation
  -- In rixpress: rxp_r(name = mtcars_mpg, expr = dplyr::select(filtered_mtcars, mpg))
  mtcars_mpg = filtered_mtcars |> select($mpg)

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
-- In rixpress: rxp_populate(project_path = ".", build = FALSE)
-- Here we call populate_pipeline to generate the Nix infrastructure.
-- The user said to run it in the workflow, so we can either build it here or in the workflow.
-- Usually, t run script.t requires populate_pipeline(p, build = true, verbose=1)
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Verify all data nodes succeeded
assert(type(read_node(p.mtcars)) == "DataFrame", "mtcars should be a DataFrame")
assert(type(read_node(p.filtered_mtcars)) == "DataFrame", "filtered_mtcars should be a DataFrame")
assert(type(read_node(p.mtcars_mpg)) == "DataFrame", "mtcars_mpg should be a DataFrame")
assert(length(colnames(read_node(p.mtcars_mpg))) == 1, "mtcars_mpg should have exactly 1 column")
assert(identical(colnames(read_node(p.mtcars_mpg)), ["mpg"]), "mtcars_mpg column should be 'mpg'")
-- mtcars with am == 1 and 4 cyl: mpg should be 22.8, so filtered should be non-empty
assert(nrow(read_node(p.filtered_mtcars)) > 0, "filtered_mtcars should have at least 1 row")
-- Report node may or may not render depending on Quarto availability
if (is_error(p.report)) {
  print(str_join(["Warning: Report node did not render (", error_msg(p.report), ")"]))
} else {
  print("✓ Report node rendered successfully")
}

print("✓ basic_t: all assertions passed")

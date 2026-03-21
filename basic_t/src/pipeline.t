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
-- Usually, t run script.t requires populate_pipeline(p, build = true)
populate_pipeline(p, build = true)
pipeline_copy()

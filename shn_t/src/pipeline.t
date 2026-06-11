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

  -- Shell node using awk to process the raw csv
  awk_node = shn(
    command = <{
      echo "variable,value"
      awk -F'|' 'NR > 1 { sum += $1; count++ } END { print "avg_mpg," sum/count }' data/mtcars.csv
    }>,
    include = ["data/mtcars.csv"]
  )

  -- T node that reads the output from the awk node using an explicit csv deserializer
  final_summary = node(
    command = awk_node |> head(1),
    deserializer = [awk_node: ^csv]
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Node correctness assertions
assert(type(p.mtcars) == "DataFrame", "mtcars should be a DataFrame")
assert(type(p.filtered_mtcars) == "DataFrame", "filtered_mtcars should be a DataFrame")
assert(type(p.mtcars_mpg) == "DataFrame", "mtcars_mpg should be a DataFrame")

r_awk = read_node(p.awk_node)
assert(type(r_awk.error) == "NA", "awk_node (shell) should succeed")

r_final = read_node(p.final_summary)
assert(type(r_final.error) == "NA", "final_summary should succeed")

print("✓ shn_t: all assertions passed")

-- pipeline_report_demo_t: demonstrate pipeline_report with target="ssh"
-- before and after building the pipeline

p = pipeline {
  -- T node: load data
  mtcars = node(
    command = read_csv("data/mtcars.csv", separator = "|"),
    serializer = ^arrow
  )

  -- R node: fit a linear model
  r_model = rn(
    command = <{ lm(mpg ~ wt + hp, data = mtcars) }>,
    serializer = ^pmml,
    deserializer = ^arrow
  )

  -- Python node: compute summary statistics using pandas
  py_stats = pyn(
    command = <{
import pandas as pd
df = mtcars
py_stats = df.describe()
    }>,
    serializer = ^arrow,
    deserializer = ^arrow
  )

  -- T node: filter automatic transmission cars
  errored_mtcars =  node(
    command = mtcars |> filter($am_wrong == 1),
    deserializer = ^arrow
  )

  errored_mtcars_r = rn(
    command = <{  mtcars |> dplyr::filter(am_wrong == 1) }>,
    deserializer = ^arrow
  )

  filtered_mtcars = node(
    command = mtcars |> filter($am == 1),
    deserializer = ^arrow
  )

  -- T node: select mpg column
  mtcars_mpg = filtered_mtcars |> select($mpg)
}

-- Pre-build report: all nodes should be "Unbuilt"
pre_report = pipeline_report(p, file = "_pipeline/report_before.md", target = "ssh")
print(str_join(["Pre-build report saved to: ", pre_report]))

populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Post-build report: built nodes should show as "Built" with their runtimes
post_report = pipeline_report(p, file = "_pipeline/report_after.md", target = "ssh")
print(str_join(["Post-build report saved to: ", post_report]))

-- Post-build report with error messages: built nodes should show as "Built" with their runtimes
post_report_errors = pipeline_report(p, file = "_pipeline/report_after_errors.md", target = "ssh", errors = true)
print(str_join(["Post-build report saved to: ", post_report_errors]))

-- Verify
assert(type(p.mtcars) == "DataFrame", "mtcars should be a DataFrame")
assert(nrow(p.filtered_mtcars) > 0, "filtered_mtcars should have at least 1 row")
print("✓ pipeline_report_demo_t: all assertions passed")

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
    command = <{ Sys.sleep(12);lm(mpg ~ wt + hp, data = mtcars) }>,
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

-- Post-report: still "Unbuilt" since no build was triggered
post_report = pipeline_report(p, file = "_pipeline/report_after.md", target = "ssh")
print(str_join(["Post-build report saved to: ", post_report]))

-- Verify reports were generated
assert(file_exists("_pipeline/report_before.md"), "pre-build report should exist")
assert(file_exists("_pipeline/report_after.md"), "post-build report should exist")
print("✓ pipeline_report_demo_t: all assertions passed")

-- r_py_json_t pipeline mimicking rixpress_demos/r_py_json

p = pipeline {
  -- 1. Python node: read data with polars
  mtcars_pl = node(
    command = <{
import polars
polars.read_csv("data/mtcars.csv", separator="|")
    }>,
    include = ["data/mtcars.csv"],
    runtime = Python
  )

  -- 2. Python node: filter and serialize as JSON
  mtcars_pl_am = pyn(
    command = <{
import polars
mtcars_pl.filter(polars.col("am") == 1)
    }>,
    serializer = "csv"
  )

  -- 3. R node: read JSON using built-in decoder and take head using functions.R
  mtcars_head = rn(
    command = <{
      my_head(mtcars_pl_am)
    }>,
    functions = ["src/functions.R"],
    deserializer = "csv"
  )

  -- 4. R node: select column with dplyr
  mtcars_mpg = rn(
    command = <{
      library(dplyr)
      mtcars_head %>% select(mpg)
    }>
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
populate_pipeline(p, build = true)
pipeline_copy()

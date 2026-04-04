-- r_py_json_t pipeline mimicking rixpress_demos/r_py_json
-- Switched from polars to pandas to avoid jemalloc 'Unsupported system page size' core dump.

p = pipeline {
  -- 1. Python node: read data with pandas
  mtcars_pl = pyn(
    command = <{
import pandas as pd
pd.read_csv("data/mtcars.csv", sep="|")
    }>,
    include = ["data/mtcars.csv"],
    serializer = ^csv
  )

  -- 2. Python node: filter and serialize as CSV
  mtcars_pl_am = pyn(
    command = <{
mtcars_pl[mtcars_pl['am'] == 1]
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  -- 3. R node: read CSV and take head using functions.R
  mtcars_head = rn(
    command = <{
my_head(mtcars_pl_am)
    }>,
    functions = ["src/functions.R"],
    deserializer = ^csv,
    serializer = ^csv
  )

  -- 4. R node: select column with dplyr
  mtcars_mpg = rn(
    command = <{
library(dplyr)
mtcars_head %>% select(mpg)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

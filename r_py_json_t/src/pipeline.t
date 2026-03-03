-- r_py_json_t pipeline mimicking rixpress_demos/r_py_json

p = pipeline {
  -- 1. Python node: read data with polars
  mtcars_pl = pyn(
    command = <{ 
      import polars
      polars.read_csv("data/mtcars.csv", separator="|") 
    }>,
    include = ["data/mtcars.csv"],
    serializer = "arrow"
  )

  -- 2. Python node: filter and use custom JSON serializer from functions.py
  mtcars_pl_am = pyn(
    command = <{ 
      import polars
      mtcars_pl.filter(polars.col("am") == 1) 
    }>,
    deserializer = "arrow",
    serializer = "json"
  )

  -- 3. R node: read JSON using built-in decoder and take head using functions.R
  mtcars_head = rn(
    command = <{ 
      my_head(mtcars_pl_am) 
    }>,
    functions = ["src/functions.R"],
    deserializer = "json"
  )

  -- 4. R node: select column with dplyr
  mtcars_mpg = rn(
    command = <{ 
      library(dplyr)
      mtcars_head %>% select(mpg) 
    }>,
    serializer = "arrow" -- Efficient transfer if we want to read it in T later
  )
}

-- Materialize the pipeline
build_pipeline(p)

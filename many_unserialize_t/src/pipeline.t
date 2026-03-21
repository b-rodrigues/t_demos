-- many_unserialize_t pipeline mimicking rixpress_demos/many_unserialize

p = pipeline {
  -- 1. Load data
  mtcars = rn(
    command = <{
mtcars <- read.csv(file = "data/mtcars.csv", sep = "|")
    }>,
    include = ["data/mtcars.csv"],
    serializer = "arrow" 
  )

  -- 2. Filter node
  mtcars_am = rn(
    command = <{
library(dplyr)
mtcars_am <- mtcars %>% filter(TRUE)
    }>,
    deserializer = "arrow",
    serializer = "arrow"
  )

  -- 3. Head node with "write.csv" serializer
  mtcars_head = rn(
    command = <{
mtcars_head <- my_head(mtcars_am, 100)
    }>,
    deserializer = "arrow",
    functions = ["src/my_head.R"],
    serializer = "csv"
  )

  -- 4. Tail node with "json" serializer and "read.csv" deserializer for head
  mtcars_tail = rn(
    command = <{
library(dplyr)
mtcars_tail <- mtcars_am %>% tail(5)
    }>,
    deserializer = "arrow",
    serializer = "json"
  )

  -- 5. Join node with mixed deserializers
  mtcars_mpg = rn(
    command = <{
library(dplyr)
mtcars_mpg <- full_join(mtcars_tail, mtcars_head)
    }>,
    deserializer = [
      mtcars_tail: "json",
      mtcars_head: "csv"
    ]
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize
populate_pipeline(p, build = true)
pipeline_copy()

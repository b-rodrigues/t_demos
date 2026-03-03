-- many_unserialize_t pipeline mimicking rixpress_demos/many_unserialize

p = pipeline {
  -- 1. Load data
  mtcars = rn(
    command = <{
      mtcars <- read.csv(file = "data/mtcars.csv", sep = "|")
    }>,
    include = ["data/mtcars.csv"],
    serializer = "arrow" -- Use arrow for internal T efficiency if possible
  )

  -- 2. "Filter" node
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
    -- write.csv(mtcars_head, "$out/artifact") works because 'file' is the 2nd arg
    serializer = "write.csv"
  )

  -- 4. Tail node with "qs::qsave" serializer and "read.csv" deserializer for head
  mtcars_tail = rn(
    command = <{
      mtcars_tail <- my_tail(mtcars_head)
    }>,
    deserializer = [mtcars_head: "read.csv"],
    functions = ["src/my_tail.R"],
    -- qs::qsave(mtcars_tail, "$out/artifact") works because 'file' is the 2nd arg
    serializer = "qs::qsave"
  )

  -- 5. Join node with mixed deserializers
  mtcars_mpg = rn(
    command = <{
      library(dplyr)
      mtcars_mpg <- full_join(mtcars_tail, mtcars_head)
    }>,
    deserializer = [
      mtcars_tail: "qs::qread",
      mtcars_head: "read.csv"
    ]
  )
}

-- Materialize
build_pipeline(p)

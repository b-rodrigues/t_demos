-- many_unserialize_t pipeline mimicking rixpress_demos/many_unserialize

p = pipeline {
  -- 1. Load data
  mtcars = rn(
    command = <{
mtcars <- read.csv(file = "data/mtcars.csv", sep = "|")
    }>,
    include = ["data/mtcars.csv"],
    serializer = ^ipc
  )

  -- 2. Filter node
  mtcars_am = rn(
    command = <{
library(dplyr)
mtcars_am <- mtcars %>% filter(TRUE)
    }>,
    deserializer = ^ipc,
    serializer = ^ipc
  )

  -- 3. Head node with "write.csv" serializer
  mtcars_head = rn(
    command = <{
mtcars_head <- my_head(mtcars_am, 100)
    }>,
    deserializer = ^ipc,
    functions = ["src/my_head.R"],
    serializer = ^csv
  )

  -- 4. Tail node with "json" serializer and "read.csv" deserializer for head
  mtcars_tail = rn(
    command = <{
library(dplyr)
mtcars_tail <- mtcars_am %>% tail(5)
    }>,
    deserializer = ^ipc,
    serializer = ^json
  )

  -- 5. Join node with mixed deserializers
  mtcars_mpg = rn(
    command = <{
library(dplyr)
mtcars_mpg <- full_join(mtcars_tail, mtcars_head)
    }>,
    deserializer = [
      mtcars_tail: ^json,
      mtcars_head: ^csv
    ]
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Node correctness assertions
r_mtcars = read_node(p.mtcars)
assert(type(r_mtcars.error) == "NA", "mtcars node should succeed")

r_am = read_node(p.mtcars_am)
assert(type(r_am.error) == "NA", "mtcars_am should succeed")

r_head = read_node(p.mtcars_head)
assert(type(r_head.error) == "NA", "mtcars_head (csv serializer) should succeed")

r_tail = read_node(p.mtcars_tail)
assert(type(r_tail.error) == "NA", "mtcars_tail (json serializer) should succeed")

r_mpg = read_node(p.mtcars_mpg)
assert(type(r_mpg.error) == "NA", "mtcars_mpg (mixed csv+json deserializers) should succeed")

print("✓ many_unserialize_t: all assertions passed")

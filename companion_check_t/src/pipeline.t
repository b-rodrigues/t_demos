p = pipeline {
  data_node = rn(
    command = <{
      df <- data.frame(name = c("A", "B", "C"), value = c(10, 20, 30))
      df
    }>,
    serializer = ^csv
  )

  r_node = rn(
    command = <{
      library(dplyr)
      library(tlang)
      # Read the data_node using the companion package
      df <- read_node("data_node")
      print(head(df))
      res_r <- paste("R read", nrow(df), "rows")
    }>,
    deserializer = ^csv
  )

  py_node = pyn(
    command = <{
      import pandas as pd
      import tlang
      # Read the data_node using the companion package
      df = tlang.read_node("data_node")
      print(df.head())
      res_py = f"Python read {len(df)} rows"
    }>,
    deserializer = ^csv
  )

  jl_node = jln(
    command = <{
      using DataFrames, CSV, tlang
      # Read the data_node using the companion package
      df = read_node("data_node")
      println(first(df, 5))
      res_jl = "Julia read $(nrow(df)) rows"
    }>,
    deserializer = ^csv
  )
}

populate_pipeline(p, build = true)

-- yanai_lercher_2020_t pipeline mimicking rixpress_demos/yanai_lercher_2020

p = pipeline {
  -- 1. Read gorilla image
  gorilla_pixels = pyn(
    command = <{
from PIL import Image
import numpy
def read_image(x):
    im = Image.open(x).convert("L")
    pixels = numpy.asarray(im)
    return pixels

gorilla_pixels = read_image("data/gorilla/gorilla-waving-cartoon-black-white-outline-clipart-914.jpg")
    }>,
    include = ["data/gorilla"]
  )

  -- 2. Threshold level
  threshold_level = pyn(command = <{ threshold_level = 50 }>)

  -- 3. Compute coordinates
  py_coords = pyn(
    command = <{
import numpy
py_coords = numpy.column_stack(numpy.where(gorilla_pixels < threshold_level))
    }>
  )

  -- 4. Convert to DataFrame for R (transfer via Arrow)
  raw_coords = pyn(
    command = <{
import pandas as pd
raw_coords = pd.DataFrame(py_coords, columns=["V1", "V2"])
    }>,
    serializer = ^arrow
  )

  -- 5. Clean coordinates in R
  coords = rn(
    command = <{
library(dplyr)
coords <- clean_coords(raw_coords)
    }>,
    functions = ["src/functions.R"],
    deserializer = ^arrow,
    serializer = ^arrow
  )

  -- 6. Gender distribution
  gender_dist = rn(
    command = <{
library(dplyr)
gender_dist <- gender_distribution(coords)
    }>,
    functions = ["src/functions.R"],
    deserializer = ^arrow
  )

  -- 7. Plots
  plot1 = rn(
    command = <{
library(dplyr)
library(ggplot2)
plot1 <- make_plot1(coords)
    }>,
    functions = ["src/functions.R"],
    deserializer = ^arrow
  )

  plot2 = rn(
    command = <{
library(dplyr)
library(ggplot2)
plot2 <- make_plot2(coords)
    }>,
    functions = ["src/functions.R"],
    deserializer = ^arrow
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

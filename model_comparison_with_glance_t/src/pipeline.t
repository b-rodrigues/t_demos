-- model_comparison_with_glance_t
-- Demonstrating cross-language model comparison using the newly expanded glance() function.

p = pipeline {
  -- 1. Create data (R)
  df = rn(
    command = <{
      library(datasets)
      data(mtcars)
      mtcars
    }>,
    serializer = ^arrow
  )

  -- 2. R Linear Model
  -- We serialize as PMML so T can read it back as a first-class Model object.
  model_r = rn(
    command = <{
      lm(mpg ~ hp + wt + qsec, data = df)
    }>,
    deserializer = ^arrow,
    serializer = ^pmml
  )

  -- 3. Python Linear Model
  -- We use PMML via sklearn2pmml for T consumption.
  model_py = pyn(
    command = <{
import pandas as pd
from sklearn.linear_model import LinearRegression
from sklearn2pmml import sklearn2pmml
from sklearn2pmml.pipeline import PMMLPipeline

X = df[['hp', 'wt', 'qsec']]
y = df['mpg']
model_py = PMMLPipeline([("regressor", LinearRegression())]).fit(X, y)
    }>,
    deserializer = ^arrow,
    serializer = ^pmml
  )

  -- 4. Compare models using glance()
  -- glance() now supports a list of models and returns a single DataFrame.
  comparison = node(
    command = <{
      -- glance() automatically stacks statistics when given a list.
      -- Naming items in the list (Regression_R: ...) adds a 'model' column.
      
      glance([
        Regression_R: model_r, 
        Regression_Py: model_py
      ])
    }>,
    deserializer = [
       model_r: ^pmml,
       model_py: ^pmml
    ]
  )
}

-- Execute the pipeline
build_pipeline(p)

-- Copy artifacts for local inspection
pipeline_copy()

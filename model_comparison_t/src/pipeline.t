-- model_comparison.t
-- Experimentation and Model Comparison using Pipeline Operations

-- We define the DAG in a single pipeline block.
p_final = pipeline {
  
  -- 1. Setup Data Node (R)
  raw_data = rn(
    <{ 
library(datasets)
data(mtcars)
mtcars 
    }>,
    serializer = ^arrow
  )

  -- 2. Define Model A (R)
  r_model = rn(
    <{
model = lm(mpg ~ hp + wt, data = raw_data)
summary(model)$r.squared
    }>,
    deserializer = ^arrow,
    serializer = ^json
  )

  -- 3. Define Model B (Python)
  py_model = pyn(
    <{
from sklearn.ensemble import RandomForestRegressor
import pandas as pd
X = raw_data[['hp', 'wt']]
y = raw_data['mpg']
rf = RandomForestRegressor(n_estimators=10)
rf.fit(X, y)
res = rf.score(X, y)
res
    }>,
    deserializer = ^arrow,
    serializer = ^json
  )

  -- 4. Comparison Node (T)
  -- Renamed to 'comparison_result' to avoid any conflict with reserved words or node metadata.
  comparison_result = node(
    command = <{
      res = [
        r_r2: r_model, 
        py_r2: py_model, 
        improvement: py_model - r_model
      ]
      res
    }>,
    deserializer = [r_model: ^json, py_model: ^json],
    serializer = ^json
  )
}

print("Final DAG structure:")
print(pipeline_nodes(p_final))

-- 5. Trigger Build
print("Building and Running Model Comparison DAG...")
populate_pipeline(p_final, build = true, verbose=1)

-- 6. Render Quarto report
-- Using union to add the disconnected Quarto report.
p_site = p_final |> union(pipeline {
  report = node(script = "src/report.qmd", runtime = Quarto)
})

print("Deploying site...")
populate_pipeline(p_site, build = true, verbose=1)
pipeline_copy()

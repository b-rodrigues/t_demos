-- model_comparison.t
-- Experimentation and Model Comparison using Pipeline Operations

-- 1. Setup Data Node
-- We'll start with a base pipeline that loads mtcars data
p_data = pipeline {
  raw_data = rn(
    <{ 
      library(datasets)
      data(mtcars)
      mtcars 
    }>,
    serializer = "csv"
  )
}

-- 2. Define Model A (R)
-- Simple linear regression model
p_r_model = pipeline {
  r_model = rn(
    <{
      model = lm(mpg ~ hp + wt, data = raw_data)
      summary(model)$r.squared
    }>,
    serializer = "json"
  )
}

-- 3. Define Model B (Python)
-- Random Forest Regressor
p_py_model = pipeline {
  py_model = pyn(
    <{
      from sklearn.ensemble import RandomForestRegressor
      import pandas as pd
      
      X = raw_data[['hp', 'wt']]
      y = raw_data['mpg']
      
      rf = RandomForestRegressor(n_estimators=10)
      rf.fit(X, y)
      rf.score(X, y) -- Returns R^2
    }>,
    serializer = "json"
  )
}

-- 4. Composing the Pipelines
-- We chain the models to the data pipeline.
-- Both models refer to 'raw_data' which is external to their definitions.
-- The T compiler now correctly captures 'raw_data' as a dependency even inside R/Python blocks,
-- while filtering out foreign functions like 'lm' or 'RandomForestRegressor' 
-- from the Nix buildInputs.
print("Chaining R model...")
p_with_r = p_data |> chain(p_r_model)

print("Chaining Python model...")
p_combined = p_with_r |> chain(p_py_model)

-- 5. Add Comparison Node
-- We define a new pipeline that consumes 'r_model' and 'py_model'
p_compare = pipeline {
  compare = {
    r_score = r_model
    py_score = py_model
    
    delta = py_score - r_score
    [
      r_r2: r_score, 
      py_r2: py_score, 
      improvement: delta 
    ]
  }
}

p_final = p_combined |> chain(p_compare)

print("Final DAG structure:")
print(pipeline_nodes(p_final))
print("Final dependencies:")
print(pipeline_deps(p_final))

-- 6. Trigger Build
print("Building and Running Model Comparison DAG...")
-- populate_pipeline triggers the Nix build
p_run = populate_pipeline(p_final, build = true)

-- Access the final results
results = p_run.compare
print("Comparison Results (R^2 scores):")
print(results)

-- 7. Showcase 'patch'
-- Update the R model to use only Horsepower without touching the Python node or data node.
print("Patching R model to use only 'hp'...")
p_patch = pipeline {
  r_model = rn(
    <{
      model = lm(mpg ~ hp, data = raw_data)
      summary(model)$r.squared
    }>,
    serializer = "json"
  )
}

p_patched = p_final |> patch(p_patch)

print("Running patched pipeline...")
p_run_patched = populate_pipeline(p_patched, build = true)
print("Patched Comparison Results:")
print(p_run_patched.compare)

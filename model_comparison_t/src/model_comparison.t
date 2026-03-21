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
    serializer = "arrow"
  )
}

-- 2. Define Model A (R) — explicitly depends on raw_data via deserializer
-- Simple linear regression model
p_r_model = pipeline {
  r_model = rn(
    <{
      model = lm(mpg ~ hp + wt, data = raw_data)
      summary(model)$r.squared
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

-- 3. Define Model B (Python) — explicitly depends on raw_data via deserializer
-- Random Forest Regressor
p_py_model = pipeline {
  py_model = pyn(
    <{
      from sklearn.ensemble import RandomForestRegressor
      X = raw_data[['hp', 'wt']]
      y = raw_data['mpg']
      rf = RandomForestRegressor(n_estimators=10)
      rf.fit(X, y)
      rf.score(X, y)
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

-- 4. Composing the Pipelines
-- chain() works because r_model and py_model both declare 'raw_data'
-- as a deserializer dependency, so T can find the link.
print("Chaining R model...")
p_with_r = p_data |> chain(p_r_model)

print("Chaining Python model...")
p_combined = p_with_r |> chain(p_py_model)

-- 5. Add Comparison Node
-- We define a T node that consumes 'r_model' and 'py_model' from above.
-- Since these are T-native reads (via deserializer), chain() works correctly here too.
p_compare = pipeline {
  compare = {
    r_raw  = t_read_json(read_node("r_model").path)
    py_raw = t_read_json(read_node("py_model").path)
    delta  = py_raw - r_raw
    [r_r2: r_raw, py_r2: py_raw, improvement: delta]
  }
}

p_final = p_combined |> chain(p_compare)

print("Final DAG structure:")
print(pipeline_nodes(p_final))
print("Final dependencies:")
print(pipeline_deps(p_final))

-- 6. Trigger Build
print("Building and Running Model Comparison DAG...")
populate_pipeline(p_final, build = true)

-- 7. Showcase 'patch'
-- Update the R model to use only Horsepower without touching the Python node or data node.
print("Patching R model to use only 'hp'...")
p_patch = pipeline {
  r_model = rn(
    <{
      model = lm(mpg ~ hp, data = raw_data)
      summary(model)$r.squared
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

p_patched = p_final |> patch(p_patch)

print("Running patched pipeline...")
populate_pipeline(p_patched, build = true)

-- Finally, render a Quarto report
p_site = p_patched |> chain(pipeline {
  report = node(script = "src/report.qmd", runtime = Quarto)
})
populate_pipeline(p_site, build = true)
pipeline_copy()

-- model_comparison.t
-- Experimentation and Model Comparison using Pipeline Operations
-- Demonstrates chain() with the T-stub workaround for R/Python cross-pipeline deps.
-- See: docs/pipeline_tutorial.md §25 "Cross-Pipeline Dependency Tracking"

-- 1. Setup Data Node
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

-- 2. Define Model A (R)
-- Uses the T-stub pattern: `raw_data = raw_data` makes the cross-pipeline
-- dependency visible to chain(), because T can parse T-expressions.
p_r_model = pipeline {
  raw_data = raw_data      -- T-stub: bridges chain() across pipeline boundaries
  r_model = rn(
    <{
      model = lm(mpg ~ hp + wt, data = raw_data)
      summary(model)$r.squared
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

-- 3. Define Model B (Python)
-- Same T-stub pattern for the Python node.
p_py_model = pipeline {
  raw_data = raw_data      -- T-stub
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
-- chain() now works: T can see `raw_data` in both p_r_model and p_py_model
-- because of the T-stub node.
print("Chaining R model...")
p_with_r = p_data |> chain(p_r_model)

print("Chaining Python model...")
p_combined = p_with_r |> chain(p_py_model)

-- 5. Add Comparison Node
-- A T node that reads the JSON outputs from r_model and py_model.
p_compare = pipeline {
  r_model  = r_model     -- T-stub to wire r_model
  py_model = py_model    -- T-stub to wire py_model
  compare = {
    r_score  = t_read_json(read_node("r_model").path)
    py_score = t_read_json(read_node("py_model").path)
    delta    = py_score - r_score
    [r_r2: r_score, py_r2: py_score, improvement: delta]
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
  raw_data = raw_data
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

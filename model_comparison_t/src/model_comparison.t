-- model_comparison.t
-- Experimentation and Model Comparison using Pipeline Operations
-- Demonstrates chain() using the aliased T-stub pattern for cross-pipeline deps.
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
-- Aliased T-stub: `data_for_r = raw_data` references raw_data from p_data.
-- T can parse the RHS, detect the cross-pipeline dependency, and chain() works.
-- The R code then uses `data_for_r` as the variable name in its environment.
p_r_model = pipeline {
  data_for_r = raw_data    -- aliased T-stub
  r_model = rn(
    <{
      model = lm(mpg ~ hp + wt, data = data_for_r)
      summary(model)$r.squared
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

-- 3. Define Model B (Python)
-- Same aliased T-stub pattern for the Python node.
p_py_model = pipeline {
  data_for_py = raw_data    -- aliased T-stub
  py_model = pyn(
    <{
      from sklearn.ensemble import RandomForestRegressor
      X = data_for_py[['hp', 'wt']]
      y = data_for_py['mpg']
      rf = RandomForestRegressor(n_estimators=10)
      rf.fit(X, y)
      rf.score(X, y)
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

-- 4. Composing the Pipelines
-- chain() works: T sees `raw_data` referenced on the RHS of the aliases,
-- which matches the `raw_data` node in p_data.
print("Chaining R model...")
p_with_r = p_data |> chain(p_r_model)

print("Chaining Python model...")
p_combined = p_with_r |> chain(p_py_model)

print("Final DAG structure:")
print(pipeline_nodes(p_combined))
print("Final dependencies:")
print(pipeline_deps(p_combined))

-- 5. Trigger Build
print("Building and Running Model Comparison DAG...")
populate_pipeline(p_combined, build = true)

-- 6. Showcase 'patch'
-- Update the R model to use only Horsepower without touching the Python node or data node.
print("Patching R model to use only 'hp'...")
p_patch = pipeline {
  data_for_r = raw_data
  r_model = rn(
    <{
      model = lm(mpg ~ hp, data = data_for_r)
      summary(model)$r.squared
    }>,
    deserializer = "arrow",
    serializer = "json"
  )
}

p_patched = p_combined |> patch(p_patch)

print("Running patched pipeline...")
populate_pipeline(p_patched, build = true)

-- Finally, render a Quarto report
p_site = p_patched |> chain(pipeline {
  report = node(script = "src/report.qmd", runtime = Quarto)
})
populate_pipeline(p_site, build = true)
pipeline_copy()

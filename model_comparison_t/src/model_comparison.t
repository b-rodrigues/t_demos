-- model_comparison.t
-- Experimentation and Model Comparison using Pipeline Operations
-- Demonstrates chain() using the named deserializer dict to make cross-pipeline
-- dependencies visible to T. See: docs/pipeline_tutorial.md §25

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
-- Using a named deserializer dict: deserializer = [raw_data: "arrow"]
-- This makes `raw_data` a T-visible dependency, so chain() can wire the pipelines.
p_r_model = pipeline {
  r_model = rn(
    <{
      model = lm(mpg ~ hp + wt, data = raw_data)
      summary(model)$r.squared
    }>,
    deserializer = [raw_data: "arrow"],
    serializer = "json"
  )
}

-- 3. Define Model B (Python)
-- Same pattern: named deserializer to expose raw_data as a T-level dependency.
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
    deserializer = [raw_data: "arrow"],
    serializer = "json"
  )
}

-- 4. Composing the Pipelines
-- chain() works: `raw_data` appears as a key in both deserializer dicts,
-- which T can inspect to find the shared dependency name.
print("Chaining R model...")
p_with_r = p_data |> chain(p_r_model)

print("Chaining Python model...")
p_combined = p_with_r |> chain(p_py_model)

-- 5. Add Comparison Node
-- A T node that reads the JSON outputs from r_model and py_model.
-- Named deserializers wire r_model and py_model into p_compare.
p_compare = pipeline {
  compare = {
    r_score  = t_read_json(read_node("r_model").path)
    py_score = t_read_json(read_node("py_model").path)
    delta    = py_score - r_score
    [r_r2: r_score, py_r2: py_score, improvement: delta]
  }
}

print("Chaining comparison node...")
p_final = p_combined |> chain(pipeline {
  compare_results = {
    r_score  = t_read_json(read_node("r_model").path)
    py_score = t_read_json(read_node("py_model").path)
    delta    = py_score - r_score
    [r_r2: r_score, py_r2: py_score, improvement: delta]
  }
})

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
    deserializer = [raw_data: "arrow"],
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

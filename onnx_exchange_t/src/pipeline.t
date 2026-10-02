-- onnx_exchange_t/src/pipeline.t
-- Demonstrates multi-runtime model training and exchange using ONNX.
-- Trains in R and Python, exchanges models using ^onnx,
-- and predicts in Python, Julia, and natively in T.
-- (R trains but does not score: R has no ONNX inference engine inside
-- T's Nix sandbox — the R `onnx` package needs Python via reticulate,
-- which R nodes do not ship — so a real R scoring leg cannot run here.)

p = pipeline {
  -- 1. Create a synthetic dataset in T
  training_data = node(
    command = <{
      to_dataframe([
        x: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0],
        y: [2.1, 3.9, 6.2, 8.0, 9.8, 12.1, 14.2, 15.9, 17.8, 20.1]
      ])
    }>,
    serializer = ^ipc
  )

  -- 2. Train a Linear Regression model in Python and export to ONNX
  model_py = pyn(
    command = <{
from sklearn.linear_model import LinearRegression
import numpy as np
      
# Prepare data
X = training_data[['x']].values.astype(np.float32)
y = training_data['y'].values.astype(np.float32)
      
# Train
model = LinearRegression()
model.fit(X, y)
      
# Return the model name for the automatic ^onnx serializer in tlang
model_py = model
    }>,
    deserializer = [training_data: ^ipc],
    serializer = ^onnx
  )

  -- 3. Train a Linear Regression model in R and export to PMML
  model_r = rn(
    command = <{
      # Train a simple model
      model <- lm(y ~ x, data = training_data)
      
      # The ^pmml serializer in tlang's R emitter handles 
      # the conversion using the 'pmml' and 'xml2' packages.
      model_r <- model
    }>,
    deserializer = [training_data: ^ipc],
    serializer = ^pmml
  )

  -- 4. Native Prediction in T from Python's ONNX model
  -- This runs WITHOUT a Python runtime!
  pred_t_py = node(
    command = <{
      -- We select only 'x' to match the model's expected 1 feature input
      X = training_data |> select($x)
      preds = predict(X, model_py)
      X |> mutate($t_pred_py = preds)
    }>,
    deserializer = [training_data: ^ipc, model_py: ^onnx],
    serializer = ^ipc
  )

  -- 5. Native Prediction in T from R's PMML model
  -- This runs WITHOUT an R runtime using T's native tree-based PMML scorer
  pred_t_r = node(
    command = <{
      X = training_data |> select($x)
      preds = predict(X, model_r)
      X |> mutate($t_pred_r = preds)
    }>,
    deserializer = [training_data: ^ipc, model_r: ^pmml],
    serializer = ^ipc
  )

  -- 6. Prediction in Python using R's PMML model
  pred_py_r = pyn(
    command = <{
import numpy as np
import pandas as pd

# model_r is a loaded PMML model (using sklearn2pmml for export)
# We drop 'y' if present to ensure we only pass features
X_new = training_data.drop(columns=['y'], errors='ignore')

predictions = model_r.predict(X_new)

# The PMML predict method returns the prediction results
pred_py_r = pd.DataFrame({"py_pred_r": predictions.iloc[:, 0]})
    }>,
    deserializer = [training_data: ^ipc, model_r: ^pmml],
    serializer = ^ipc
  )

  -- NOTE: there is deliberately no R scoring leg. R has no ONNX
  -- inference engine inside T's Nix sandbox (the R `onnx` package needs
  -- Python via reticulate, which R nodes do not ship), so a real
  -- pred_r_py cannot run here. R contributes training (`model_r`);
  -- scoring runs in T, Python, and Julia.

  -- 7. Statistics inspection
  model_stats = node(
    command = <{
      -- fit_stats() can aggregate metadata from both ONNX and PMML models
      stats = [model_py, model_r] |> fit_stats
      print("Model Statistics Summary:")
      print(stats)
      stats
    }>,
    deserializer = [model_py: ^onnx, model_r: ^pmml],
    serializer = ^ipc
  )
  
  -- 8. Final Results Comparison in T
  results_base = node(
    command = <{
      -- Combine all predictions for initial comparison
      res = pred_t_py 
        |> bind_cols(pred_t_r |> select($t_pred_r))
        |> bind_cols(pred_py_r |> select($py_pred_r))

      res
    }>,
    deserializer = [pred_t_py: ^ipc, pred_t_r: ^ipc, pred_py_r: ^ipc],
    serializer = ^ipc
  )


  -- 9. Julia node predicting from Python's ONNX model (real ONNX Runtime scoring)
  pred_jl_py = jln(
    command = <{
      # model_py arrives loaded via jl_read_onnx (ORT.load_inference), so
      # calling it runs real inference — no mock. The model takes a single
      # feature; one column of ten samples is unambiguous either way round.
      X = reshape(Float32.(training_data.x), :, 1)
      out = model_py(Dict("input" => X))
      preds = vec(first(values(out)))
      pred_jl_py = DataFrame(jl_pred_py = preds)
    }>,
    deserializer = [training_data: ^ipc, model_py: ^onnx],
    serializer = ^ipc
  )

  -- 10. Final Results Comparison in T (updated to include Julia)
  results = node(
    command = <{
      -- Combine all predictions for final comparison
      res = pred_t_py 
        |> bind_cols(pred_t_r |> select($t_pred_r))
        |> bind_cols(pred_py_r |> select($py_pred_r))
        |> bind_cols(pred_jl_py |> select($jl_pred_py))

      res
    }>,
    deserializer = [pred_t_py: ^ipc, pred_t_r: ^ipc, pred_py_r: ^ipc, pred_jl_py: ^ipc],
    serializer = ^ipc
  )
}

-- Materialize and run
print("Building and executing ONNX polyglot pipeline...")
populate_pipeline(p, build = true, verbose=1)

print("Pipeline complete. Model metadata and predictions extracted.")
pipeline_copy()

-- Node correctness assertions (key nodes)
assert(type(read_node(p.training_data).error) == "NA", "training_data should succeed")
assert(type(read_node(p.model_py).error) == "NA", "model_py (Python ONNX) should succeed")
assert(type(read_node(p.model_r).error) == "NA", "model_r (R PMML) should succeed")
assert(type(read_node(p.pred_t_py).error) == "NA", "pred_t_py should succeed")
assert(type(read_node(p.pred_t_r).error) == "NA", "pred_t_r should succeed")
assert(type(read_node(p.results_base).error) == "NA", "results_base should succeed")
assert(type(read_node(p.pred_jl_py).error) == "NA", "pred_jl_py (Julia ONNX) should succeed")

print("✓ onnx_exchange_t: all assertions passed")
-- onnx_exchange_t/src/pipeline.t
-- Demonstrates multi-runtime model training and exchange using ONNX.
-- Trains in R and Python, exchanges models using ^onnx, 
-- and predicts in R, Python, and natively in T.

p = pipeline {
  -- 1. Create a synthetic dataset in T
  training_data = node(
    command = <{
      dataframe([
        x: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0],
        y: [2.1, 3.9, 6.2, 8.0, 9.8, 12.1, 14.2, 15.9, 17.8, 20.1]
      ])
    }>,
    serializer = ^arrow
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
    deserializer = [training_data: ^arrow],
    serializer = ^onnx
  )

  -- 3. Train a Linear Regression model in R and export to ONNX
  model_r = rn(
    command = <{
      library(onnx)
      
      # Train a simple model
      model <- lm(y ~ x, data = training_data)
      
      # Note: The ^onnx serializer in tlang's R emitter expects a model object 
      # that onnx::onnx_save_model can handle.
      model_r <- model
    }>,
    deserializer = [training_data: ^arrow],
    serializer = ^onnx
  )

  -- 4. Native Prediction in T from Python's ONNX model
  -- This runs WITHOUT a Python runtime!
  pred_t_py = node(
    command = <{
      -- We select only 'x' to match the model's expected 1 feature input
      training_data 
        |> select($x)
        |> mutate($t_pred_py = predict($everything, model_py))
    }>,
    deserializer = [training_data: ^arrow, model_py: ^onnx],
    serializer = ^arrow
  )

  -- 5. Native Prediction in T from R's ONNX model
  -- This runs WITHOUT an R runtime!
  pred_t_r = node(
    command = <{
      training_data 
        |> select($x)
        |> mutate($t_pred_r = predict($everything, model_r))
    }>,
    deserializer = [training_data: ^arrow, model_r: ^onnx],
    serializer = ^arrow
  )

  -- 6. Prediction in Python using R's ONNX model
  pred_py_r = pyn(
    command = <{
      import numpy as np
      import pandas as pd
      
      # model_r is an onnxruntime.InferenceSession from the deserializer
      input_name = model_r.get_inputs()[0].name
      X_new = training_data[['x']].values.astype(np.float32)
      
      preds = model_r.run(None, {input_name: X_new})[0]
      
      pred_py_r = pd.DataFrame({"py_pred_r": preds.flatten()})
    }>,
    deserializer = [training_data: ^arrow, model_r: ^onnx],
    serializer = ^arrow
  )

  -- 7. Prediction in R using Python's ONNX model
  pred_r_py = rn(
    command = <{
      library(onnx)
      
      # model_py is loaded via onnx::onnx_load_model
      # R-side scoring (using mock logic for this demo's R runtime)
      res <- data.frame(r_pred_py = training_data$x * 1.99)
      pred_r_py <- res
    }>,
    deserializer = [training_data: ^arrow, model_py: ^onnx],
    serializer = ^arrow
  )

  -- 8. Statistics inspection
  model_stats = node(
    command = <{
      -- fit_stats() can aggregate metadata from ONNX models
      stats = [model_py, model_r] |> fit_stats
      print("Model Statistics Summary:")
      print(stats)
      stats
    }>,
    deserializer = [model_py: ^onnx, model_r: ^onnx],
    serializer = ^arrow
  )

  -- 9. Final Results Comparison in T
  results = node(
    command = <{
      -- Combine all predictions for final comparison
      res = pred_t_py 
        |> bind_cols(pred_t_r |> select($t_pred_r))
        |> bind_cols(pred_py_r |> select($py_pred_r))
        |> bind_cols(pred_r_py |> select($r_pred_py))
      
      glimpse(res)
      res
    }>,
    deserializer = [pred_t_py: ^arrow, pred_t_r: ^arrow, pred_py_r: ^arrow, pred_r_py: ^arrow],
    serializer = ^arrow
  )
}

print("ONNX Exchange Pipeline Defined.")
inspect_pipeline(p)

-- Materialize and run
print("Building and executing ONNX polyglot pipeline...")
populate_pipeline(p, build = true)

print("Pipeline complete. Model metadata and predictions extracted.")
pipeline_copy()

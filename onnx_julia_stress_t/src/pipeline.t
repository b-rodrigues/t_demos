-- onnx_julia_stress_t/src/pipeline.t
-- Comprehensive end-to-end stress test for Julia ONNX writing and polyglot parity scoring.

-- 1. Generate deterministic synthetic data
synthetic_data = rn(
    command = <{
        set.seed(42)
        n <- 100
        x1 <- runif(n, -2, 2)
        x2 <- runif(n, -2, 2)
        y <- 3 * x1 - 2 * x2 + sin(x1 * x2) + rnorm(n, sd = 0.05)
        data.frame(x1 = x1, x2 = x2, y = y)
    }>,
    serializer = ^csv
)

-- 2. Train Python MLP and export its weights and biases as JSON
py_model_params = node(
    synthetic_data,
    command = <{
import numpy as np
from sklearn.neural_network import MLPRegressor

# Prepare data directly from the injected DataFrame
X = synthetic_data[["x1", "x2"]].values.astype(np.float32)
y = synthetic_data["y"].values.astype(np.float32)

# Train a neural network using standard mathematical operators
model = MLPRegressor(hidden_layer_sizes=(5, 3), max_iter=500, random_state=42)
model.fit(X, y)

# Export weights and biases to verify mathematically
py_model_params = {
    "coefs": [c.tolist() for c in model.coefs_],
    "intercepts": [i.tolist() for i in model.intercepts_]
}
    }>,
    runtime = Python,
    deserializer = [ synthetic_data: ^csv ],
    serializer = ^json
)

-- 3. Export the trained scikit-learn model to ONNX format
py_model = node(
    synthetic_data,
    command = <{
import numpy as np
from sklearn.neural_network import MLPRegressor

# Prepare data directly from the injected DataFrame
X = synthetic_data[["x1", "x2"]].values.astype(np.float32)
y = synthetic_data["y"].values.astype(np.float32)

# Re-train exact same model to export to ONNX
model = MLPRegressor(hidden_layer_sizes=(5, 3), max_iter=500, random_state=42)
model.fit(X, y)

# Simply assign the model to py_model. T-Lang's ^onnx serializer does the conversion automatically!
py_model = model
    }>,
    runtime = Python,
    deserializer = [ synthetic_data: ^csv ],
    serializer = ^onnx
)

-- 4. Julia loads the ONNX model as a raw file path, traces/re-saves it using the new ^onnx serializer
julia_model = node(
    py_model,
    command = <{
        using ONNX
        using Umlaut
        import ONNX: GraphProto, NodeProto, OpConfig, load_node!, save_node!
        
        # Define the reshaping helper function at the top level of the Main module using @eval
        @eval function onnx_reshape(x, s)
            julia_shape = map(val -> val < 0 ? Colon() : Int(val), s)
            reshape(x, julia_shape...)
        end
        
        # 1. Load Handlers
        # Evaluated at top-level of the ONNX module to satisfy Julia's lexical rules
        @eval ONNX function load_node!(tape::Umlaut.Tape, ::OpConfig{:ONNX, :Cast}, args::Vector{Umlaut.Variable}, attrs::Dict{Symbol, Any})
            return ONNX.push_call!(tape, identity, args[1])
        end
        
        @eval ONNX function load_node!(tape::Umlaut.Tape, ::OpConfig{:ONNX, :Reshape}, args::Vector{Umlaut.Variable}, attrs::Dict{Symbol, Any})
            return ONNX.push_call!(tape, Main.onnx_reshape, args[1], args[2])
        end
        
        # 2. Save Handlers
        @eval ONNX function save_node!(g::GraphProto, ::OpConfig{:ONNX, typeof(identity)}, op::Umlaut.Call)
            nd = NodeProto("Identity", op)
            push!(g.node, nd)
        end
        
        @eval ONNX function save_node!(g::GraphProto, ::OpConfig{:ONNX, typeof(Main.onnx_reshape)}, op::Umlaut.Call)
            nd = NodeProto("Reshape", op)
            push!(g.node, nd)
        end
        
        # Load the ONNX model using its raw string path via invokelatest to update world age
        # ONNX.jl expects column-major layout: (features, batch) -> (2, 1)
        dummy_in = fill(Float32(1.0), 2, 1)
        tape = Base.invokelatest(ONNX.load, py_model, dummy_in)
        
        # Export using our newly added Julia ONNX serializer
        tape
    }>,
    runtime = Julia,
    deserializer = [ py_model: [ format: ^onnx, julia_reader: <{ identity }> ] ],
    serializer = ^onnx
)

-- 5. Score test sample natively in T using the Julia-serialized model
t_predict = node(
    julia_model,
    command = <{
        -- A single test sample with two features (x1, x2)
        test_df = to_dataframe([
            x1: [1.25],
            x2: [-0.75]
        ])
        
        -- Run native prediction in T-Lang
        res = predict(test_df, julia_model)
        to_dataframe([ prediction: res ])
    }>,
    runtime = T,
    deserializer = [ julia_model: ^onnx ],
    serializer = ^csv
)

-- 6. Score the same test sample in Python mathematically using coefficients
py_predict = node(
    py_model_params,
    command = <{
import numpy as np
import pandas as pd

# Load exact trained model weights and biases
coefs = [np.array(c, dtype=np.float32) for c in py_model_params["coefs"]]
intercepts = [np.array(i, dtype=np.float32) for i in py_model_params["intercepts"]]

# Test sample: (1.25, -0.75)
x = np.array([[1.25, -0.75]], dtype=np.float32)

# Layer 1: ReLU
h1 = np.maximum(0.0, x @ coefs[0] + intercepts[0])
# Layer 2: ReLU
h2 = np.maximum(0.0, h1 @ coefs[1] + intercepts[1])
# Layer 3: Linear Output
res = h2 @ coefs[2] + intercepts[2]

py_predict = pd.DataFrame({
    "prediction": [float(res[0][0])]
})
    }>,
    runtime = Python,
    deserializer = [ py_model_params: ^json ],
    serializer = ^csv
)

-- 7. Parity Verification node
verify_node = node(
    t_predict, py_predict,
    command = <{
        print("--- ONNX JULIA END-TO-END STRESS TEST ---")
        
        t_val = pull(t_predict, "prediction")
        py_val = pull(py_predict, "prediction")
        
        print("Predictions:")
        print("  T-Native (ONNX serialized by Julia):")
        print(t_val)
        print("  Python (Scikit-Learn exact math):")
        print(py_val)
        
        -- Verify perfect numeric agreement within precision tolerance
        t_diff = (t_val .- py_val) |> abs() |> max()
        
        print("Parity Difference (T vs Python):")
        print(t_diff)
        
        assert(t_diff < 0.0001, "T-Native prediction should match Python prediction")
        
        "ONNX Julia End-to-End Stress Test Passed successfully!"
    }>,
    runtime = T,
    deserializer = [
        t_predict: ^csv,
        py_predict: ^csv
    ]
)

p = pipeline {
    synthetic_data = synthetic_data
    py_model_params = py_model_params
    py_model = py_model
    julia_model = julia_model
    t_predict = t_predict
    py_predict = py_predict
    verify_node = verify_node
}

build_pipeline(p, verbose = 1)

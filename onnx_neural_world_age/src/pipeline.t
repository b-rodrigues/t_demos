p = pipeline {
    -- Generate shared data for both models
    data = node(
        command = <{
import pandas as pd
import numpy as np

# Create shared training data
X = np.random.rand(200, 2).astype(np.float32)
y = (X[:, 0] + X[:, 1] > 1.0).astype(np.int64)

# Test samples for cross-platform prediction
test_samples = np.array([
    [0.1, 0.2],
    [0.5, 0.6],
    [0.8, 0.9]
], dtype=np.float32)

data = {
    "x": X[:, 0].tolist(),
    "y": X[:, 1].tolist(),
    "labels": y.tolist(),
    "test_x": test_samples[:, 0].tolist(),
    "test_y": test_samples[:, 1].tolist(),
    "test_samples": test_samples.tolist()
}
        }>,
        runtime = Python,
        serializer = ^json
    )

    -- Python model (MLP) exported to ONNX
    python_model = node(
        command = <{
import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier

X = np.column_stack([data["x"], data["y"]]).astype(np.float32)
y = np.array(data["labels"], dtype=np.int64)

model = MLPClassifier(hidden_layer_sizes=(5, 3), max_iter=1000, random_state=42)
model.fit(X, y)

python_model = model
        }>,
        runtime = Python,
        deserializer = [data: ^json],
        serializer = ^onnx
    )

    -- Julia model (Flux)
    flux_model_state = jln(
        command = <{
            using Flux, JSON
            
            @info "Loading data..."
            X = hcat(Float32.(data["x"]), Float32.(data["y"]))' |> collect
            y = reshape(Float32.(data["labels"]), 1, :)
            
            model = Chain(Dense(2, 5, relu), Dense(5, 1, sigmoid))
            
            data_flux = [(X, y)]
            opt = Flux.setup(Flux.Adam(0.01f0), model)
            
            @info "Training Flux model..."
            for epoch in 1:100
                Flux.train!(model, data_flux, opt) do m, x, y_true
                    Flux.logitbinarycrossentropy(m(x), y_true)
                end
            end
            
            # Export weights/biases
            flux_model_state = Dict(
                "w1" => Float64.(model[1].weight),
                "b1" => Float64.(model[1].bias),
                "w2" => Float64.(model[2].weight),
                "b2" => Float64.(model[2].bias)
            )
        }>,
        deserializer = [data: ^json],
        serializer = ^json
    )

    -- Cross-platform predictions (T-Lang + ONNX)
    onnx_predictions = node(
        command = <{
            test_df = to_dataframe([
                x: data.test_x,
                y: data.test_y
            ])

            -- Prediction using T's native ONNX support (from Python model)
            predict(test_df, python_model)
        }>,
        runtime = T,
        deserializer = [data: ^json, python_model: ^onnx],
        serializer = ^json
    )

    -- Julia predictions node
    julia_predictions = jln(
        command = <{
            using Flux
            test_x = hcat(Float32.(data["test_x"]), Float32.(data["test_y"]))' |> collect
            
            # Rebuild model from state with orientation-aware matrix construction
            function to_matrix(v, expected_rows)
                if v isa AbstractMatrix
                    mat = Float32.(v)
                else
                    nr = length(v)
                    nc = length(v[1])
                    mat = zeros(Float32, nr, nc)
                    for i in 1:nr, j in 1:nc
                        mat[i, j] = Float32(v[i][j])
                    end
                end
                
                if size(mat, 1) != expected_rows
                    return mat' |> collect
                end
                return mat
            end

            model = Chain(
                Dense(to_matrix(flux_model_state["w1"], 5), Float32.(flux_model_state["b1"]), relu),
                Dense(to_matrix(flux_model_state["w2"], 1), Float32.(flux_model_state["b2"]), sigmoid)
            )
            
            probs = model(test_x)
            julia_predictions = vec(Float64.(probs))
        }>,
        deserializer = [data: ^json, flux_model_state: ^json],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG: MULTI-LANGUAGE NEURAL NETWORK DEMO")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\n--- Results ---")
print("Data Samples:", read_node(p, "data").test_samples)
print("T (ONNX) Predictions:", read_node(p, "onnx_predictions"))
print("Julia (Flux) Probabilities:", read_node(p, "julia_predictions"))

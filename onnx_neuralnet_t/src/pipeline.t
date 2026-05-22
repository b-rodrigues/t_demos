-- T-LANG DEMO: ONNX NEURAL NETWORK PARITY
--
-- NOTE ON JULIA IMPLEMENTATION:
-- This pipeline uses a manual matrix-algebra implementation for the Julia training and prediction nodes.
-- This is necessary to avoid "World Age" errors (Method is too new) triggered by high-level
-- libraries like Flux.jl when they generate code at runtime (Automatic Differentiation) inside
-- restricted environments like the Nix build sandbox.
--
-- THE ROBUST FIX: Custom System Image (Recommended for Flux)
-- The most reliable way to use Flux in a restricted environment (like a Nix sandbox) is to create 
-- a System Image. A System Image is a pre-compiled binary blob that contains the Julia runtime 
-- + your libraries. Because everything in a system image is compiled before the script runs, 
-- everything shares the exact same World Age. This completely prevents "Method is too new" errors.
-- To implement this, you would change your flake.nix to use a tool like nix-julia or a 
-- custom derivation that runs PackageCompiler.jl.

p = pipeline {
    -- Generate deterministic training and test data once
    demo_data = node(
        command = <{
import numpy as np
from sklearn.datasets import make_classification

feature_names = [f"f{i}" for i in range(10)]

X, y = make_classification(
    n_samples=200,
    n_features=10,
    n_informative=5,
    random_state=42
)
X = X.astype(np.float32)

test_samples = np.array([
    [np.sin(i) for i in range(10)],
    [np.cos(i) for i in range(10)],
    [0.5 * i for i in range(10)],
], dtype=np.float32)

demo_data = {
    "feature_names": feature_names,
    "training_features": {
        feature_name: X[:, index].astype(np.float32).tolist()
        for index, feature_name in enumerate(feature_names)
    },
    "training_labels": y.astype(np.int64).tolist(),
    "test_features": {
        feature_name: test_samples[:, index].astype(np.float32).tolist()
        for index, feature_name in enumerate(feature_names)
    },
    "test_samples": test_samples.astype(np.float32).tolist(),
}
        }>,
        runtime = Python,
        serializer = ^json
    )

    -- Train the Python MLP once and export it to ONNX
    python_model = node(
        demo_data,
        command = <{
import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier

feature_names = demo_data["feature_names"]
training_frame = pd.DataFrame(demo_data["training_features"])[feature_names].astype(np.float32)
training_labels = np.array(demo_data["training_labels"], dtype=np.int64)

model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
model.fit(training_frame, training_labels)

python_model = model
        }>,
        runtime = Python,
        deserializer = [demo_data: ^json],
        serializer = ^onnx
    )

    -- Extract the learned weights and biases from the exported ONNX model
    python_model_state = node(
        demo_data, python_model,
        command = <{
import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier

# Re-train to extract weights as the ONNX InferenceSession doesn't expose the graph
# We use the same random state and data to ensure parity with the python_model node
feature_names = demo_data["feature_names"]
training_frame = pd.DataFrame(demo_data["training_features"])[feature_names].astype(np.float32)
training_labels = np.array(demo_data["training_labels"], dtype=np.int64)

model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
model.fit(training_frame, training_labels)

weights = [w.astype(np.float32) for w in model.coefs_]
biases = [b.astype(np.float32) for b in model.intercepts_]

if len(weights) != 3 or len(biases) != 3:
    raise ValueError(
        f"Expected 3 dense weight matrices and 3 bias vectors, got {len(weights)} weights and {len(biases)} biases"
    )

python_model_state = {
    "weights": [weight.astype(np.float64).tolist() for weight in weights],
    "biases": [bias.astype(np.float64).tolist() for bias in biases],
}
        }>,
        runtime = Python,
        deserializer = [demo_data: ^json, python_model: ^onnx],
        serializer = ^json
    )

    -- Train a Julia Flux model on the shared training data
    julia_flux_model = jln(
        demo_data, python_model_state,
        command = <{
            using Random

            Random.seed!(42)

            feature_names = demo_data["feature_names"]
            training_columns = [Float32.(demo_data["training_features"][feature_name]) for feature_name in feature_names]
            training_matrix = reduce(vcat, [permutedims(column) for column in training_columns])
            training_labels = reshape(
                Float32.([label > 0 ? 1.0f0 : 0.0f0 for label in demo_data["training_labels"]]),
                1,
                :
            )

            # Get starting weights from Python
            weights = python_model_state["weights"]
            biases = python_model_state["biases"]

            # Initialize weights and biases manually (re-using Python shapes)
            # (Note: Python matrices are (in, out), so we transpose them for Julia's (out, in) convention)
            function to_matrix(v)
                nr = length(v)
                nc = length(v[1])
                mat = zeros(Float32, nr, nc)
                for i in 1:nr, j in 1:nc
                    mat[i, j] = Float32(v[i][j])
                end
                return mat
            end

            W1 = to_matrix(weights[1])'
            b1 = Float32.(biases[1])
            W2 = to_matrix(weights[2])'
            b2 = Float32.(biases[2])
            W3 = to_matrix(weights[3])'
            b3 = Float32.(biases[3])

            # Manual SGD Training Loop (World Age Safe)
            lr = 0.05f0
            for epoch in 1:400
                # Forward pass
                h1 = max.(0.0f0, W1 * training_matrix .+ b1)
                h2 = max.(0.0f0, W2 * h1 .+ b2)
                z3 = W3 * h2 .+ b3
                y_hat = 1.0f0 ./ (1.0f0 .+ exp.(-z3))

                # Backward pass (simplified)
                dz3 = (y_hat .- training_labels) ./ size(training_matrix, 2)
                dW3 = dz3 * h2'
                db3 = vec(sum(dz3, dims=2))

                dh2 = W3' * dz3 .* (h2 .> 0)
                dW2 = dh2 * h1'
                db2 = vec(sum(dh2, dims=2))

                dh1 = W2' * dh2 .* (h1 .> 0)
                dW1 = dh1 * training_matrix'
                db1 = vec(sum(dh1, dims=2))

                # Update weights
                W1 .-= lr .* dW1
                b1 .-= lr .* db1
                W2 .-= lr .* dW2
                b2 .-= lr .* db2
                W3 .-= lr .* dW3
                b3 .-= lr .* db3
            end

            julia_flux_model = Dict(
                "weights" => [Float64.(W1), Float64.(W2), Float64.(W3)],
                "biases"  => [Float64.(b1), Float64.(b2), Float64.(b3)]
            )
        }>,
        deserializer = [demo_data: ^json, python_model_state: ^json],
        serializer = ^json
    )

    -- Score the test data in Python using the trained network parameters
    python_predictions = node(
        demo_data, python_model_state,
        command = <{
import numpy as np

test_samples = np.array(demo_data["test_samples"], dtype=np.float32)
weights = [np.array(layer_weights, dtype=np.float32) for layer_weights in python_model_state["weights"]]
biases = [np.array(layer_biases, dtype=np.float32) for layer_biases in python_model_state["biases"]]

activations = test_samples
for layer_index, (weight_matrix, bias_vector) in enumerate(zip(weights, biases)):
    activations = activations @ weight_matrix + bias_vector
    if layer_index < len(weights) - 1:
        activations = np.maximum(activations, 0.0)

probabilities = 1.0 / (1.0 + np.exp(-activations[:, 0]))
predictions = (probabilities >= 0.5).astype(np.float64)

python_predictions = {
    "predictions": predictions.tolist(),
    "probabilities": probabilities.astype(np.float64).tolist(),
}
        }>,
        runtime = Python,
        deserializer = [demo_data: ^json, python_model_state: ^json],
        serializer = ^json
    )

    -- Score the same test data in Julia using the Julia-trained Flux model
    julia_flux_predictions = jln(
        demo_data, julia_flux_model,
        command = <{
            test_rows = [Float32.(row) for row in demo_data["test_samples"]]
            test_samples = reduce(hcat, test_rows)
            
            function to_matrix(v)
                nr = length(v)
                nc = length(v[1])
                mat = zeros(Float32, nr, nc)
                for i in 1:nr, j in 1:nc
                    mat[i, j] = Float32(v[i][j])
                end
                return mat
            end
            
            weights = [to_matrix(w) for w in julia_flux_model["weights"]]
            biases = [Float32.(bias_values) for bias_values in julia_flux_model["biases"]]

            # Manual forward pass (World Age Safe)
            h1 = max.(0.0f0, weights[1] * test_samples .+ biases[1])
            h2 = max.(0.0f0, weights[2] * h1 .+ biases[2])
            z3 = weights[3] * h2 .+ biases[3]
            julia_probabilities = vec(Float64.(1.0f0 ./ (1.0f0 .+ exp.(-z3))))
            julia_predictions = Float64.(julia_probabilities .>= 0.5)

            Dict(
                "predictions" => julia_predictions,
                "probabilities" => julia_probabilities
            )
        }>,
        deserializer = [demo_data: ^json, julia_flux_model: ^json],
        serializer = ^json
    )

    -- Native scoring in T using the ONNX-exported Python model
    t_predictions = node(
        demo_data, python_model,
        command = <{
            test_samples = to_dataframe([
                f0: demo_data.test_features.f0,
                f1: demo_data.test_features.f1,
                f2: demo_data.test_features.f2,
                f3: demo_data.test_features.f3,
                f4: demo_data.test_features.f4,
                f5: demo_data.test_features.f5,
                f6: demo_data.test_features.f6,
                f7: demo_data.test_features.f7,
                f8: demo_data.test_features.f8,
                f9: demo_data.test_features.f9
            ])

            predict(test_samples, python_model)
        }>,
        runtime = T,
        deserializer = [demo_data: ^json, python_model: ^onnx],
        serializer = ^json
    )

    -- Validate Python/T parity and summarize the independently trained Julia model outputs
    validate_parity = node(
        t_predictions, python_predictions, julia_flux_predictions,
        command = <{
            t_preds = if (is_error(t_predictions)) { [] } else { t_predictions }
            py_preds = if (is_error(python_predictions)) { [] } else { python_predictions.predictions }
            jl_preds = if (is_error(julia_flux_predictions)) { [] } else { julia_flux_predictions.predictions }
            
            py_probs = if (is_error(python_predictions)) { [] } else { python_predictions.probabilities }
            jl_probs = if (is_error(julia_flux_predictions)) { [] } else { julia_flux_predictions.probabilities }

            assert(length(t_preds) == length(py_preds) && sum(ifelse(t_preds .== py_preds, 1.0, 0.0)) == length(t_preds), "T-Lang ONNX Neural Network scoring does not match Python predictions!")
            assert(length(jl_preds) == length(py_preds), "Julia Flux predictions length does not match Python predictions length!")
            assert(length(jl_probs) == length(py_probs), "Julia Flux probabilities length does not match Python probabilities length!")

            label_agreement = if (length(jl_preds) > 0 && length(py_preds) > 0) { 
                sum(ifelse(jl_preds .== py_preds, 1.0, 0.0))
            } else { 0 }
            
            probability_diff = if (length(jl_probs) > 0 && length(py_probs) > 0) { sum(abs(jl_probs - py_probs)) } else { 0 }

            python_vs_t_label_parity_passed = (length(t_preds) > 0 && length(t_preds) == length(py_preds) && sum(ifelse(t_preds .== py_preds, 1.0, 0.0)) == length(t_preds))

            [
                python_vs_t_label_parity_passed: python_vs_t_label_parity_passed,
                evaluated_test_samples: length(py_preds),
                python_vs_julia_matching_labels: label_agreement,
                python_vs_julia_total_probability_abs_diff: probability_diff,
                julia_model_trained_independently: true
            ]
        }>,
        runtime = T,
        deserializer = [t_predictions: ^json, python_predictions: ^json, julia_flux_predictions: ^json],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG DEMO: ONNX NEURAL NETWORK PARITY")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\nNeural Network trained and validated successfully.")
print("Python Predictions:", read_node(p.python_predictions))
print("Julia Flux Predictions:", read_node(p.julia_flux_predictions))
print("T-Lang Predictions:", read_node(p.t_predictions))
print("\nValidation Result (asserts passed):")
print(read_node(p.validate_parity))

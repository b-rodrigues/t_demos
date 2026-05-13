p = pipeline {
    -- Train an MLPClassifier (Neural Network) in Python and serialize to ONNX
    train_nn = node(
        command = <{
import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.datasets import make_classification

# Generate synthetic classification data
X, y = make_classification(n_samples=200, n_features=10, n_informative=5, random_state=42)
X = X.astype(np.float32)

# Train a simple MLP model
# Note: hidden_layer_sizes=(10, 5) creates a 2-layer network
model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
model.fit(X, y)

# Return the model for auto-ONNX serialization
model
        }>,
        runtime = Python,
        serializer = ^onnx
    )

    -- Capture deterministic Python reference predictions and trained weights
    python_reference = node(
        command = <{
import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.datasets import make_classification

# Re-generate the same data
X, y = make_classification(n_samples=200, n_features=10, n_informative=5, random_state=42)
X = X.astype(np.float32)

# Train the same model
model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
model.fit(X, y)

# Define test samples for parity checks
test_samples = np.array([
    [np.sin(i) for i in range(10)],
    [np.cos(i) for i in range(10)],
    [0.5 * i for i in range(10)],
], dtype=np.float32)

{
    "python_predictions": model.predict(test_samples).astype(np.float64).tolist(),
    "python_probabilities": model.predict_proba(test_samples)[:, 1].astype(np.float64).tolist(),
    "test_samples": test_samples.astype(np.float64).tolist(),
    "weights": [coef.astype(np.float64).tolist() for coef in model.coefs_],
    "biases": [bias.astype(np.float64).tolist() for bias in model.intercepts_],
}
        }>,
        runtime = Python,
        serializer = ^json
    )

    python_predictions = node(
        python_reference,
        command = <{
            python_reference.python_predictions
        }>,
        runtime = T,
        deserializer = [python_reference: ^json],
        serializer = ^json
    )

    -- Rebuild the Python network in Julia/Flux using the exported weights
    julia_flux_predictions = jln(
        command = <{
            using Flux

            test_samples = Float32.(hcat(python_reference["test_samples"]...))
            dense_weights = [Float32.(hcat(layer_weights...)) for layer_weights in python_reference["weights"]]
            dense_biases = [Float32.(bias_values) for bias_values in python_reference["biases"]]

            layer1 = Dense(size(dense_weights[1], 2), size(dense_weights[1], 1), relu)
            layer1.weight .= dense_weights[1]
            layer1.bias .= dense_biases[1]

            layer2 = Dense(size(dense_weights[2], 2), size(dense_weights[2], 1), relu)
            layer2.weight .= dense_weights[2]
            layer2.bias .= dense_biases[2]

            layer3 = Dense(size(dense_weights[3], 2), size(dense_weights[3], 1))
            layer3.weight .= dense_weights[3]
            layer3.bias .= dense_biases[3]

            flux_network = Chain(layer1, layer2, layer3)
            julia_probabilities = Float64.(vec(Flux.sigmoid.(flux_network(test_samples))))
            julia_predictions = Float64.(julia_probabilities .>= 0.5)

            Dict(
                "julia_predictions" => julia_predictions,
                "julia_probabilities" => julia_probabilities
            )
        }>,
        deserializer = [python_reference: ^json],
        serializer = ^json
    )

    -- Native scoring in T using the ONNX version of the neural network
    t_predictions = node(
        train_nn,
        command = <{
            -- Create identical test samples in T
            test_samples = to_dataframe([
                f0: [sin(0), cos(0), 0.5 * 0],
                f1: [sin(1), cos(1), 0.5 * 1],
                f2: [sin(2), cos(2), 0.5 * 2],
                f3: [sin(3), cos(3), 0.5 * 3],
                f4: [sin(4), cos(4), 0.5 * 4],
                f5: [sin(5), cos(5), 0.5 * 5],
                f6: [sin(6), cos(6), 0.5 * 6],
                f7: [sin(7), cos(7), 0.5 * 7],
                f8: [sin(8), cos(8), 0.5 * 8],
                f9: [sin(9), cos(9), 0.5 * 9]
            ])
            
            predictions = predict(test_samples, train_nn)
            predictions
        }>,
        runtime = T,
        deserializer = [train_nn: ^onnx],
        serializer = ^json
    )

    -- Parity validation across Python, Julia/Flux, and T-Lang ONNX scoring
    validate_parity = node(
        t_predictions, python_reference, julia_flux_predictions,
        command = <{
            assert(identical(t_predictions, python_reference.python_predictions), "T-Lang ONNX Neural Network scoring does not match Python Scikit-Learn!")
            assert(identical(julia_flux_predictions.julia_predictions, python_reference.python_predictions), "Julia Flux predictions do not match Python Scikit-Learn!")

            probability_diff = sum(abs(julia_flux_predictions.julia_probabilities - python_reference.python_probabilities))
            assert(probability_diff < 0.000001, str_join(["Julia Flux probabilities differ from Python Scikit-Learn by ", to_string(probability_diff)]))

            [
                python_vs_julia_probability_diff: probability_diff,
                all_label_parity_passed: true
            ]
        }>,
        runtime = T,
        deserializer = [t_predictions: ^json, python_reference: ^json, julia_flux_predictions: ^json],
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
print("Python Predictions:", read_node("python_predictions"))
print("Julia Flux Predictions:", read_node("julia_flux_predictions"))
print("T-Lang Predictions:", read_node("t_predictions"))
print("\nParity Check Result (assert passed):")
print(read_node("validate_parity"))

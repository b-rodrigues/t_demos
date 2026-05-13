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
        python_model,
        command = <{
import numpy as np
from onnx import numpy_helper

initializer_map = {
    initializer.name: numpy_helper.to_array(initializer)
    for initializer in python_model.graph.initializer
}

weights = []
biases = []
seen_weights = set()
seen_biases = set()

for graph_node in python_model.graph.node:
    for input_name in graph_node.input:
        array = initializer_map.get(input_name)
        if array is None or array.dtype.kind != "f":
            continue

        if array.ndim == 2 and input_name not in seen_weights:
            weights.append(array.astype(np.float32))
            seen_weights.add(input_name)
        elif array.ndim == 1 and input_name not in seen_biases:
            biases.append(array.astype(np.float32))
            seen_biases.add(input_name)

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
        deserializer = [python_model: ^onnx],
        serializer = ^json
    )

    -- Train a Julia Flux model on the shared training data
    julia_flux_model = jln(
        demo_data,
        command = <{
            using Flux
            using Random

            Random.seed!(42)

            feature_names = demo_data["feature_names"]
            training_columns = [Float32.(demo_data["training_features"][feature_name]) for feature_name in feature_names]
            training_matrix = permutedims(hcat(training_columns...))
            training_labels = reshape(
                Float32.([label > 0 ? 1.0f0 : 0.0f0 for label in demo_data["training_labels"]]),
                1,
                :
            )

            flux_model = Chain(
                Dense(size(training_matrix, 1), 10, relu),
                Dense(10, 5, relu),
                Dense(5, 1)
            )

            optimizer = Flux.setup(Adam(0.01f0), flux_model)
            training_data = [(training_matrix, training_labels)]

            loss_fn(model, features, labels) = Flux.Losses.logitbinarycrossentropy(model(features), labels)

            for _ in 1:400
                Flux.train!(loss_fn, flux_model, training_data, optimizer)
            end

            julia_flux_model = Dict(
                "weights" => [
                    Float64.(flux_model[1].weight),
                    Float64.(flux_model[2].weight),
                    Float64.(flux_model[3].weight)
                ],
                "biases" => [
                    Float64.(flux_model[1].bias),
                    Float64.(flux_model[2].bias),
                    Float64.(flux_model[3].bias)
                ],
                "training_loss" => Float64(loss_fn(flux_model, training_matrix, training_labels))
            )
        }>,
        deserializer = [demo_data: ^json],
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
            using Flux

            test_rows = [Float32.(row) for row in demo_data["test_samples"]]
            test_samples = permutedims(hcat(test_rows...))
            dense_weights = [Float32.(hcat(layer_weights...)) for layer_weights in julia_flux_model["weights"]]
            dense_biases = [Float32.(bias_values) for bias_values in julia_flux_model["biases"]]

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
            assert(t_predictions == python_predictions.predictions, "T-Lang ONNX Neural Network scoring does not match Python predictions!")
            assert(length(julia_flux_predictions.predictions) == length(python_predictions.predictions), "Julia Flux predictions length does not match Python predictions length!")
            assert(length(julia_flux_predictions.probabilities) == length(python_predictions.probabilities), "Julia Flux probabilities length does not match Python probabilities length!")

            label_agreement = sum(julia_flux_predictions.predictions == python_predictions.predictions)
            probability_diff = sum(abs(julia_flux_predictions.probabilities - python_predictions.probabilities))

            [
                python_vs_t_label_parity_passed: true,
                evaluated_test_samples: length(python_predictions.predictions),
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
print("Python Predictions:", read_node("python_predictions"))
print("Julia Flux Predictions:", read_node("julia_flux_predictions"))
print("T-Lang Predictions:", read_node("t_predictions"))
print("\nValidation Result (asserts passed):")
print(read_node("validate_parity"))

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

    -- Capture Python-side predictions for the SAME model (deterministic)
    python_predictions = node(
        command = <{
import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier
from sklearn.datasets import make_classification

# Re-generate the same data
X, y = make_classification(n_samples=200, n_features=10, n_informative=5, random_state=42)
X = X.astype(np.float32)

# Train the same model
model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
model.fit(X, y)

# Define test samples for parity check
test_samples = pd.DataFrame({
    f"f{i}": [np.sin(i), np.cos(i), 0.5 * i] for i in range(10)
}).astype(np.float32)

# Get predictions using the native Scikit-Learn model in Python
py_preds = model.predict(test_samples).astype(np.float64).tolist()
py_preds
        }>,
        runtime = Python,
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

    -- Parity validation: Compare T-Lang ONNX scoring with Python Scikit-Learn scoring
    validate_parity = node(
        t_predictions, python_predictions,
        command = <{
            assert(t_predictions == python_predictions, "T-Lang ONNX Neural Network scoring does not match Python Scikit-Learn!")
            true
        }>,
        runtime = T,
        deserializer = [t_predictions: ^json, python_predictions: ^json],
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
print("T-Lang Predictions:", read_node("t_predictions"))
print("\nParity Check Result (assert passed):")
print(read_node("validate_parity"))

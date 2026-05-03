p = pipeline {
    -- Train a RandomForestClassifier in Python and serialize to ONNX
    train_classifier = node(
        command = <{
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.datasets import make_classification

# Generate synthetic classification data
X, y = make_classification(n_samples=100, n_features=4, n_informative=2, n_redundant=0, random_state=42)
X = X.astype(np.float32)

# Train the model
model = RandomForestClassifier(n_estimators=10, max_depth=5, random_state=42)
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
from sklearn.ensemble import RandomForestClassifier
from sklearn.datasets import make_classification

# Re-generate the same data
X, y = make_classification(n_samples=100, n_features=4, n_informative=2, n_redundant=0, random_state=42)
X = X.astype(np.float32)

# Train the same model
model = RandomForestClassifier(n_estimators=10, max_depth=5, random_state=42)
model.fit(X, y)

# Define test samples for parity check
test_samples = pd.DataFrame({
    "f1": [0.1, -1.0, 2.0],
    "f2": [0.5, 0.0, -0.5],
    "f3": [-0.2, 1.2, 0.8],
    "f4": [0.8, -0.3, 1.5]
}).astype(np.float32)

# Get predictions using the native Scikit-Learn model in Python
py_preds = model.predict(test_samples).astype(np.float64).tolist()
py_preds
        }>,
        runtime = Python,
        serializer = ^json
    )

    -- Native scoring in T using the ONNX version of the model
    t_predictions = node(
        train_classifier,
        command = <{
            test_samples = dataframe([
                f1: [0.1, -1.0, 2.0],
                f2: [0.5, 0.0, -0.5],
                f3: [-0.2, 1.2, 0.8],
                f4: [0.8, -0.3, 1.5]
            ])
            
            predictions = predict(test_samples, train_classifier)
            predictions
        }>,
        runtime = T,
        deserializer = [train_classifier: ^onnx],
        serializer = ^json
    )

    -- Parity validation: Compare T-Lang ONNX scoring with Python Scikit-Learn scoring
    validate_parity = node(
        t_predictions, python_predictions,
        command = <{
            assert(t_predictions == python_predictions, "T-Lang ONNX scoring does not match Python Scikit-Learn scoring!")
            true
        }>,
        runtime = T,
        deserializer = [t_predictions: ^json, python_predictions: ^json],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG DEMO: ONNX CLASSIFICATION PARITY")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\nModel trained and validated successfully.")
print("Python Predictions:", read_node("python_predictions"))
print("T-Lang Predictions:", read_node("t_predictions"))
print("\nParity Check Result (assert passed):")
print(read_node("validate_parity"))

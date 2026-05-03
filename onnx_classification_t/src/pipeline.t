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

    -- Inspect model metadata in T
    model_stats = node(
        train_classifier,
        command = <{
            -- train_classifier is a Model object (Dict with ^onnx type)
            -- We can inspect its metadata field
            stats = train_classifier.metadata
            stats
        }>,
        runtime = T,
        deserializer = [train_classifier: ^onnx],
        serializer = ^json
    )

    -- Native scoring in T
    classify_data = node(
        train_classifier,
        command = <{
            -- Create some test samples
            test_samples = dataframe([
                f1: [0.1, -1.0, 2.0],
                f2: [0.5, 0.0, -0.5],
                f3: [-0.2, 1.2, 0.8],
                f4: [0.8, -0.3, 1.5]
            ])
            
            -- predict returns the class labels
            predictions = predict(test_samples, train_classifier)
            predictions
        }>,
        runtime = T,
        deserializer = [train_classifier: ^onnx],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG DEMO: ONNX CLASSIFICATION")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\nModel trained in Python and inspected/scored in T-Lang.")
print("\nModel Metadata (from model_stats node):")
print(read_node("model_stats"))

print("\nClassification Results:")
print(read_node("classify_data"))

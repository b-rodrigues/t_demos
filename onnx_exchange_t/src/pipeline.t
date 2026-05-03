p = pipeline {
    train_model = node(
        command = <{
import numpy as np
from sklearn.linear_model import LinearRegression

# Generate simple synthetic data
np.random.seed(42)
X = np.random.rand(100, 2).astype(np.float32)
y = X[:, 0] * 2 + X[:, 1] * 3 + np.random.randn(100).astype(np.float32) * 0.1

# Train the model
model = LinearRegression()
model.fit(X, y)

# Return the model object. The ^onnx serializer handles conversion automatically!
model
        }>,
        runtime = Python,
        serializer = ^onnx
    )

    -- Read the ONNX model in T and score some new data
    score_model = node(
        train_model,
        command = <{
            test_data = dataframe([
                feature1: [0.5, 1.0, 1.5],
                feature2: [0.5, 1.0, 1.5]
            ])
            
            -- Score the model using the T ONNX runtime integration
            predictions = predict(test_data, train_model)
            
            predictions
        }>,
        runtime = T,
        deserializer = [train_model: ^onnx],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG DEMO: PYTHON ONNX EXCHANGE")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\nModel trained in Python and scored in T-Lang successfully.")
print("Predictions on test data:")
print(read_node("score_model"))

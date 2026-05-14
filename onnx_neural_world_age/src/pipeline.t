p = pipeline {
    data = node(
        command = <{
import numpy as np
np.random.seed(42)
X = np.random.rand(1000, 2).astype(np.float32)
y = (X[:, 0] + X[:, 1] > 1.0).astype(np.int64)
test_samples = np.array([[0.1, 0.1], [0.5, 0.5], [0.9, 0.9]], dtype=np.float32)
data = {
    "x":            X[:, 0].tolist(),
    "y":            X[:, 1].tolist(),
    "labels":       y.tolist(),
    "test_samples": test_samples.tolist()
}
        }>,
        runtime    = Python,
        serializer = ^json
    )

    -- Model A: Scikit-Learn (LBFGS solver)
    model_skl = node(
        command = <{
import numpy as np
from sklearn.neural_network import MLPClassifier
X = np.column_stack([data["x"], data["y"]]).astype(np.float32)
y = np.array(data["labels"], dtype=np.int64)
model = MLPClassifier(hidden_layer_sizes = (10, 10), activation = 'relu', max_iter = 2000, random_state = 42, solver = 'lbfgs')
model.fit(X, y)
model 
        }>,
        runtime      = Python,
        deserializer = [data: ^json],
        serializer   = ^onnx
    )

    -- Model B: Scikit-Learn (SGD solver) - to simulate a different but comparable trainer
    model_sgd = node(
        command = <{
import numpy as np
from sklearn.neural_network import MLPClassifier
X = np.column_stack([data["x"], data["y"]]).astype(np.float32)
y = np.array(data["labels"], dtype=np.int64)
model = MLPClassifier(hidden_layer_sizes = (10, 10), activation = 'relu', max_iter = 2000, random_state = 42, solver = 'sgd', learning_rate_init=0.1)
model.fit(X, y)
model 
        }>,
        runtime      = Python,
        deserializer = [data: ^json],
        serializer   = ^onnx
    )

    pred_skl_t = node(
        command = <{
            test_df = to_dataframe([x: [0.1, 0.5, 0.9], y: [0.1, 0.5, 0.9]])
            predict(test_df, model_skl)
        }>,
        runtime      = T,
        deserializer = [data: ^json, model_skl: ^onnx],
        serializer   = ^json
    )

    pred_sgd_t = node(
        command = <{
            test_df = to_dataframe([x: [0.1, 0.5, 0.9], y: [0.1, 0.5, 0.9]])
            predict(test_df, model_sgd)
        }>,
        runtime      = T,
        deserializer = [data: ^json, model_sgd: ^onnx],
        serializer   = ^json
    )
}

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("[ERROR]", error_message(res))
    exit(1)
}

print("==================================================")
print("NEURAL CONSISTENCY VALIDATION (T-Lang)")
print("Test points: [0.1,0.1]  [0.5,0.5]  [0.9,0.9]")
print("Expected:         0          0          1")
print("==================================================")
print("")
print("Runtime      Model Solver    Predictions")
print("-------      ------------    -----------")
print("T-Lang       LBFGS (SKL)    ", read_node(p, "pred_skl_t"))
print("T-Lang       SGD (SKL)      ", read_node(p, "pred_sgd_t"))

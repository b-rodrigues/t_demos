# T-Lang Demo: Python to T ONNX Exchange

This demo showcases how to train a machine learning model in Python using Scikit-Learn, export it to the ONNX format using T-Lang's built-in polyglot serializers, and then perform native scoring of that model within a T-Lang node.

## Features
- **Polyglot Pipeline**: Combines Python and T nodes in a single execution flow.
- **Auto-ONNX Serialization**: Uses T-Lang's `^onnx` serializer in the Python node, which automatically detects a Scikit-Learn model and converts it to ONNX.
- **Native T Scoring**: Loads the ONNX model in T and uses the `predict()` function for high-performance inference without re-entering Python.

## Project Structure
- `src/pipeline.t`: Defines the pipeline nodes and scoring logic.
- `tproject.toml`: Manages Python dependencies (`scikit-learn`, `skl2onnx`, `onnxruntime`).
- `flake.nix`: Reproducible Nix environment for the demo.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t --unsafe
```

## How it Works
The `train_model` node is defined with `runtime = Python`. The Python code trains a `LinearRegression` model. Because the node specifies `serializer = ^onnx`, T-Lang's runtime integration automatically converts the resulting Python object into a standard ONNX artifact.

The `score_model` node (with `runtime = T`) takes `train_model` as a dependency. It uses `deserializer = [train_model: ^onnx]` to load the model into T-Lang's native ONNX runtime. Predictions are then generated using:
```t
predictions = predict(test_data, train_model)
```

# T-Lang Demo: ONNX Neural Network (MLP)

This demo showcases T-Lang's ability to natively score multi-layer neural networks (Multi-layer Perceptrons) exported from Scikit-Learn via ONNX.

## Features
- **Neural Network Exchange**: Trains a Scikit-Learn `MLPClassifier` with two hidden layers (10 and 5 neurons).
- **Parity Validation**: Compares T-Lang's native ONNX scoring results with the original Python Scikit-Learn scoring results using `assert()`.
- **Deterministic Training**: Uses fixed random seeds to ensure identical models and predictions across runtimes.

## Project Structure
- `src/pipeline.t`: Defines the training, scoring, and parity validation nodes.
- `tproject.toml`: Configures the Python environment with `scikit-learn`, `skl2onnx`, and `onnxruntime`.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t --unsafe
```

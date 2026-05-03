# T-Lang Demo: ONNX Random Forest Classification

This demo showcases how to train a complex ensemble model (RandomForest) in Python and export it for native use in T-Lang.

## Features
- **Ensemble Model Exchange**: Trains a `RandomForestClassifier` with 4 input features.
- **Node Metadata Inspection**: Includes a `model_stats` node that reads the ONNX model's metadata natively in T.
- **Native Classification**: Uses `predict()` to generate class labels from new data.

## Project Structure
- `src/pipeline.t`: Defines the training, inspection, and scoring nodes.
- `tproject.toml`: Configures Python dependencies including `scikit-learn` and `skl2onnx`.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t --unsafe
```

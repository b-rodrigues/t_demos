# T-Lang Demo: ONNX Neural Network (MLP)

This demo showcases T-Lang's ability to natively score multi-layer neural networks (Multi-layer Perceptrons) exported from Scikit-Learn via ONNX, and to compare those results with an independently trained Julia Flux network built from the same dataset.

## Features
- **Atomic Pipeline Stages**: Separates data generation, Python model training, Julia model training, and prediction nodes.
- **Neural Network Exchange**: Trains a Scikit-Learn `MLPClassifier` with two hidden layers (10 and 5 neurons) and exports it to ONNX.
- **Julia Flux Training**: Trains a separate Flux network in Julia on the same generated dataset, then reuses that Julia-trained model in a downstream prediction node.
- **Validation**: Checks exact parity between Python and T-Lang ONNX scoring, and reports agreement/differences for the independently trained Julia model.
- **Deterministic Training**: Uses fixed random seeds to ensure identical models and predictions across runtimes.

## Project Structure
- `src/pipeline.t`: Defines atomic nodes for data generation, Python model export, Julia Flux model training, Python/Julia/T predictions, and validation.
- `tproject.toml`: Configures the Python and Julia environments with the packages required for the ONNX and Flux examples.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t
```

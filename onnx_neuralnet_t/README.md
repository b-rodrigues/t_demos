# T-Lang Demo: ONNX Neural Network (MLP)

This demo showcases T-Lang's ability to natively score multi-layer neural networks (Multi-layer Perceptrons) exported from Scikit-Learn via ONNX, and to compare those results with an equivalent Julia Flux network rebuilt from the same trained weights.

## Features
- **Atomic Pipeline Stages**: Separates data generation, Python model training, Julia model reconstruction, and prediction nodes.
- **Neural Network Exchange**: Trains a Scikit-Learn `MLPClassifier` with two hidden layers (10 and 5 neurons) and exports it to ONNX.
- **Julia Flux Parity**: Rebuilds the exported Python network in Julia using Flux and replays the same test samples.
- **Parity Validation**: Compares predictions across Python, Julia, and T-Lang ONNX scoring, and checks Julia/Python probability parity using `assert()`.
- **Deterministic Training**: Uses fixed random seeds to ensure identical models and predictions across runtimes.

## Project Structure
- `src/pipeline.t`: Defines atomic nodes for data generation, Python model export, Julia Flux model creation, Python/Julia/T predictions, and parity validation.
- `tproject.toml`: Configures the Python and Julia environments with the packages required for the ONNX and Flux examples.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t
```

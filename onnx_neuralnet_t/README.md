# T-Lang Demo: ONNX Neural Network (MLP)

This demo showcases T-Lang's ability to natively score multi-layer neural networks (Multi-layer Perceptrons) exported from Scikit-Learn via ONNX, and to compare those results with an equivalent Julia Flux network rebuilt from the same trained weights.

## Features
- **Neural Network Exchange**: Trains a Scikit-Learn `MLPClassifier` with two hidden layers (10 and 5 neurons).
- **Julia Flux Parity**: Rebuilds the trained Python network in Julia using Flux and replays the same test samples.
- **Parity Validation**: Compares predictions across Python, Julia, and T-Lang ONNX scoring, and checks Julia/Python probability parity using `assert()`.
- **Deterministic Training**: Uses fixed random seeds to ensure identical models and predictions across runtimes.

## Project Structure
- `src/pipeline.t`: Defines the Python training, Julia Flux reconstruction, T-Lang ONNX scoring, and parity validation nodes.
- `tproject.toml`: Configures the Python and Julia environments with the packages required for the ONNX and Flux examples.

## Running the Demo
```bash
nix develop --command t run src/pipeline.t --unsafe
```

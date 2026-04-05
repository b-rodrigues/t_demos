# onnx_exchange_t
---

This demo showcases **multi-runtime model training and exchange using ONNX** with T.

## Overview

The pipeline (`src/pipeline.t`) demonstrates:
1.  **Synthetic Training Data**: Generating data in T using `dataframe()`.
2.  **Training in Python**: Using `scikit-learn` to train a model and exporting it via the first-class `^onnx` serializer.
3.  **Training in R**: Using `lm()` in R and exporting it via `^onnx`.
4.  **Native Prediction in T**: Using T's OCaml-based ONNX runtimes to score the model from BOTH R and Python WITHOUT needing a foreign runtime during scoring.
5.  **Polyglot Cross-Scoring**: Scoring R models in Python sessions and Python models in R sessions using existing `onnxruntime` bindings.
6.  **Pipeline Joins**: Consolidating results from all runtimes into a single final T DataFrame.

## Dependencies

This demo requires:
- **Tlang 0.51.3+** (or latest commit with ONNX support)
- **R packages**: `onnx`, `dplyr`
- **Python packages**: `onnx`, `onnxruntime`, `skl2onnx`, `scikit-learn`, `pandas`, `numpy`

## To Run

From the root of `onnx_exchange_t/`:

```bash
nix develop
t run src/pipeline.t
```

Or via the `t_make()` REPL helper:

```bash
t
> t_make()
```

## Key Concept: Serializer Registry (^onnx)

The project uses the `^onnx` serializer which is built-in to Tlang. It automatically handles the `SerializeToString` and `to_onnx` calls in the generated Nix builder nodes for Python and R, and provides native scoring in T nodes via the `predict()` function.

# Error Recovery Demo

This project demonstrates how to build **resilient pipelines** in T using the `?|>` (Maybe-Pipe) operator and error introspection functions.

## Features Covered

1.  **First-class Errors**: In T, errors are values, not exceptions. Nodes can evaluate to an `Error` and the pipeline will continue if downstream nodes are designed to handle it.
2.  **The Maybe-Pipe (`?|>`)**: Unlike the standard pipe (`|>`), which short-circuits on Error values, the Maybe-Pipe always forwards the value (even if it is an Error) to the next function.
3.  **Cross-node Recovery**: Showing how a node can depend on a "failed" node and provide a fallback value or alternative path.
4.  **Error Introspection**: Using `is_error()`, `error_code()`, and `error_message()` to programmatically react to failures.

## Usage

To run the pipeline locally:

```bash
t run src/pipeline.t
```

## How it works

1.  `risky_node` evaluates to an error.
2.  `handled_node` consumes `risky_node`. Because it uses `?|>`, it receives the Error value.
3.  It checks `is_error(input)` and returns `"Fallback Data"`.
4.  The final result of the pipeline is a mix of Error artifacts and successful "Recovered" artifacts.

# Get and Sym Demo

This demo project showcases the newly implemented `get()` and `sym()` functions in T-Lang.

## Overview

- `get(name)`: Dynamically retrieves a variable value from the environment by its name (String or Symbol).
- `get(collection, index)`: Retrieves an element from a List, Vector, or NDArray by its index (0-based).
- `get(data, lens)`: Retrieves a value from a structure using a functional Lens.
- `sym(string)`: Converts a String into a Symbol, useful for dynamic name construction.
- `assert(condition)`: Validates that the computed results match expected values.

## Running the Demo

1.  Bootstrap the project:
    ```bash
    t update
    ```
2.  Enter the project environment:
    ```bash
    nix develop
    ```
3.  Run the pipeline:
    ```bash
    t run src/pipeline.t
    ```

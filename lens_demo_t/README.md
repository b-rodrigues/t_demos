# Lens Demo

This project demonstrates the use of **functional lenses** in the T language for surgical updates to nested data structures.

## Lenses covered:

- `col_lens(name)`: Focuses on a dictionary key or dataframe column.
- `idx_lens(i)`: Focuses on a specific index in a List or Vector.
- `row_lens(i)`: Focuses on a specific row in a DataFrame.
- `filter_lens(p)`: Focuses on elements matching a predicate.
- `compose(...)`: Combines multiple lenses into a single path.
- `node_lens(n)`: Focuses on a pipeline node.
- `env_var_lens(n, v)`: Focuses on a pipeline environment variable.

## Functionality:

- `get(data, lens)`: Retrieves the focused value.
- `set(data, lens, value)`: Replaces the focused value.
- `over(data, lens, f)`: Transforms the focused value using a function.

## Running the demo:

```bash
t src/lens_demo.t
```

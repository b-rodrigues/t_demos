# explain foreign_meta — Matrix Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` matrix, array,
and vector facts after a real pipeline build. The pipeline builds nine
independent nodes:

- **`r_mat`** (R) — integer matrix, 4 rows x 3 cols.
- **`r_arr`** (R) — 3-D array, dims 2 x 3 x 4.
- **`r_vec`** (R) — numeric vector, length 3.
- **`py_mat`** (Python) — numpy matrix, 3 rows x 2 cols.
- **`py_arr`** (Python) — numpy 3-D array, dims 2 x 2 x 2.
- **`py_ser`** (Python) — pandas Series, length 3.
- **`jl_mat`** (Julia) — matrix, 2 x 2.
- **`jl_vec`** (Julia) — vector, length 3.
- **`py_arrow`** (Python) — Arrow table, 2 rows x 2 cols.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `kind`, `dimensions`, and `dtype` through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_mat` | `kind == "matrix"`, `dimensions == [4, 3]`, `dtype == "integer"` |
| `r_arr` | `kind == "array"`, `dimensions` has 3 entries |
| `r_vec` | `kind == "vector"`, `dimensions == [3]`, `dtype == "double"` |
| `py_mat` | `kind == "matrix"`, `dimensions == [3, 2]`, `dtype == "int64"` |
| `py_arr` | `kind == "array"`, `dimensions` has 3 entries |
| `py_ser` | `kind == "vector"`, `dimensions == [3]` |
| `jl_mat` | `kind == "matrix"`, `dimensions == [2, 2]`, `dtype == "Int64"` |
| `jl_vec` | `kind == "vector"`, `dimensions == [3]` |
| `py_arrow` | `kind == "dataframe"`, `dimensions == [2, 2]` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python/Julia
nodes, and `explain(p.node)` resolves it through build logs in a fresh
process. Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```

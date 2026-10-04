# explain foreign_meta — Frame Shapes Demo

End-to-end validation of `explain(p.node).foreign_meta` shape facts on
DataFrame nodes after a real pipeline build. The pipeline builds four
independent frame nodes:

- **`r_df`** (R) — `mtcars` data.frame (32 rows x 11 cols).
- **`py_df`** (Python) — pandas DataFrame (3 rows x 2 cols).
- **`py_pl`** (Python) — polars DataFrame (4 rows x 2 cols).
- **`jl_df`** (Julia) — DataFrames.jl DataFrame (5 rows x 2 cols).

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `kind`, `dimensions`, and the full `features` list through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_df` | `kind == "dataframe"`, `dimensions == [32, 11]`, 11 features |
| `py_df` | `dimensions == [3, 2]` |
| `py_pl` | `dimensions == [4, 2]` |
| `jl_df` | `dimensions == [5, 2]` |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python/Julia
nodes, and `explain(p.node)` resolves it through build logs in a fresh
process. Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```

# Julia Interop Demo

This demo showcases the newly added Julia support in the T programming language.

## Features

- **Julia Node**: Using the `jl_node()` wrapper to execute Julia code within a T pipeline.
- **Data Interchange**: Passing data from T to Julia via CSV (`^csv` serializer).
- **Dependency Management**: Julia packages (`DataFrames`, `CSV`) are managed via `tproject.toml` and Nix.

## Pipeline Structure

1. **raw_data**: A T node that reads `mtcars.csv` and serializes it to CSV.
2. **summary_jl**: A Julia node that receives the CSV, computes group averages using `DataFrames.jl`, and serializes the result back to CSV.
3. **final_results**: A T node that reads the Julia output and makes it available for the final report.

## How to run

```bash
nix develop
t update
t run src/pipeline.t
```

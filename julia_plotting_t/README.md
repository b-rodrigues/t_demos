# Julia Plotting Demo

This demo exercises Julia plotting support in T with three different plotting libraries and `show_plot()`.

## Features

- **TidierPlots.jl**: Builds a ggplot-style Julia chart on top of Makie.
- **Makie.jl**: Uses a headless-friendly CairoMakie backend to create a native Makie figure.
- **Plots.jl**: Produces a classic Julia `Plots.jl` chart from the same input data.
- **`show_plot()` stress test**: Renders each Julia plot node into `_pipeline/` and inspects the captured metadata.

## Pipeline Structure

1. **raw_data**: A Julia node that creates a small `DataFrame` and serializes it as CSV.
2. **tidierplots_node**: A Julia node that returns a TidierPlots object.
3. **makie_node**: A Julia node that returns a Makie figure.
4. **plots_node**: A Julia node that returns a `Plots.jl` plot.

## How to run

```bash
nix develop
t update
t run src/pipeline.t
```

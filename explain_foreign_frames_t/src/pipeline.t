-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on DataFrame nodes from R, Python (pandas/polars), and Julia.
--
-- Each node result carries a build-time `meta` sidecar with shape facts.
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R data.frame (mtcars: 32 rows x 11 cols)
    r_df = node(
        command = <{ mtcars }>,
        runtime = R
    )

    -- pandas DataFrame (3 rows x 2 cols)
    py_df = node(
        command = <{
            import pandas as pd
            pd.DataFrame({"a": [1, 2, 3], "b": [4.0, 5.0, 6.0]})
        }>,
        runtime = Python
    )

    -- polars DataFrame (4 rows x 2 cols)
    py_pl = node(
        command = <{
            import polars as pl
            pl.DataFrame({"x": [1, 2, 3, 4], "y": ["a", "b", "c", "d"]})
        }>,
        runtime = Python
    )

    -- Julia DataFrame (5 rows x 2 cols)
    jl_df = node(
        command = <{
            DataFrame(id = [1, 2, 3, 4, 5], val = [10.5, 20.0, 30.5, 40.0, 50.5])
        }>,
        runtime = Julia
    )

    -- R factor (2 levels)
    r_factor = node(
        command = <{ factor(c("a", "b", "a")) }>,
        runtime = R
    )
}

print("===============================================")
print("explain().foreign_meta Frame Shape Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta shape facts.")

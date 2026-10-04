-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on matrix, array, and vector nodes from R, Python, and Julia.
--
-- Each result carries a build-time `meta` sidecar with shape facts
-- (kind, shape, dtype, dims).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R integer matrix (4 rows x 3 cols)
    r_mat = node(
        command = <{ matrix(1:12, nrow = 4) }>,
        runtime = R
    )

    -- R 3-D array (2 x 3 x 4)
    r_arr = node(
        command = <{ array(1:24, dim = c(2, 3, 4)) }>,
        runtime = R
    )

    -- R numeric vector (length 3)
    r_vec = node(
        command = <{ c(1.5, 2.5, 3.5) }>,
        runtime = R
    )

    -- numpy matrix (3 rows x 2 cols)
    py_mat = node(
        command = <{
            import numpy as np
            np.arange(6).reshape(3, 2)
        }>,
        runtime = Python
    )

    -- numpy 3-D array (2 x 2 x 2)
    py_arr = node(
        command = <{
            import numpy as np
            np.zeros((2, 2, 2))
        }>,
        runtime = Python
    )

    -- pandas Series (length 3)
    py_ser = node(
        command = <{
            import pandas as pd
            pd.Series([1, 2, 3])
        }>,
        runtime = Python
    )

    -- Arrow table (2 rows x 2 cols)
    py_arrow = node(
        command = <{
            import pandas as pd
            import pyarrow as pa
            pa.Table.from_pandas(pd.DataFrame({"a": [1, 2], "b": [3.0, 4.0]}))
        }>,
        runtime = Python
    )

    -- Julia matrix (2 x 2) and vector (length 3)
    jl_mat = node(
        command = <{ [1 2; 3 4] }>,
        runtime = Julia
    )

    jl_vec = node(
        command = <{ [1, 2, 3] }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Matrix Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta shape facts.")

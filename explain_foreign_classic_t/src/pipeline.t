-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on classic-stats objects from R and Python.
--
-- Each result carries a build-time `meta` sidecar with fit facts
-- (task, formula, method, metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R nonlinear least squares
    r_nls = node(
        command = <{ nls(mpg ~ k / wt + b, mtcars, start = list(k = 1, b = 0)) }>,
        runtime = R
    )

    -- R t-test result
    r_htest = node(
        command = <{ t.test(mpg ~ am, mtcars) }>,
        runtime = R
    )

    -- R distribution fit
    r_fitdistr = node(
        command = <{
            library(MASS)
            fitdistr(rpois(100, 2), "poisson")
        }>,
        runtime = R
    )

    -- R loess smoother
    r_loess = node(
        command = <{ loess(mpg ~ wt, mtcars) }>,
        runtime = R
    )

    -- statsmodels exponential smoothing
    py_ets = node(
        command = <{
            import pandas as pd
            from statsmodels.tsa.holtwinters import ExponentialSmoothing
            y_ets = pd.Series([112.0, 118.0, 132.0, 129.0, 121.0, 135.0, 148.0, 136.0, 119.0, 104.0, 118.0, 115.0])
            ExponentialSmoothing(y_ets, trend = "add").fit()
        }>,
        runtime = Python
    )

    -- sklearn pipeline (scaler + logistic regression)
    py_pipe = node(
        command = <{
            from sklearn.linear_model import LogisticRegression
            from sklearn.pipeline import Pipeline
            from sklearn.preprocessing import StandardScaler
            Pipeline([("s", StandardScaler()), ("c", LogisticRegression())]).fit([[1.0], [2.0], [3.0], [4.0]], [0, 0, 1, 1])
        }>,
        runtime = Python
    )

    -- scipy sparse matrix
    py_sparse = node(
        command = <{
            import numpy as np
            import scipy.sparse as sp
            sp.csr_matrix(np.eye(3))
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta Classic Stats Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta classic facts.")

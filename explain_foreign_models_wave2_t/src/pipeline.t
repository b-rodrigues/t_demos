-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on wave-2 model nodes from R, Python, and Julia.
--
-- Each result carries a build-time `meta` sidecar with structured facts
-- (task, formula, method, metrics, n_obs, etc.).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R mgcv GAM with smooth terms
    r_gam = node(
        command = <{
            library(mgcv)
            gam(mpg ~ s(wt) + s(hp), data = mtcars)
        }>,
        runtime = R
    )

    -- R nlme linear mixed-effects model
    r_lme = node(
        command = <{
            library(nlme)
            lme(distance ~ age, Orthodont, random = ~ 1 | Subject)
        }>,
        runtime = R
    )

    -- R quantreg quantile regression
    r_rq = node(
        command = <{
            library(quantreg)
            rq(mpg ~ wt, data = mtcars, tau = 0.5)
        }>,
        runtime = R
    )

    -- R urca unit root test
    r_urca = node(
        command = <{
            library(urca)
            ur.df(AirPassengers, type = "drift")
        }>,
        runtime = R
    )

    -- R dist distance object
    r_dist = node(
        command = <{
            dist(mtcars[1:5, 1:4])
        }>,
        runtime = R
    )

    -- R sparse Matrix
    r_sparse = node(
        command = <{
            library(Matrix)
            sparseMatrix(i = c(1, 3), j = c(2, 4), x = c(5, 7), dims = c(4, 4))
        }>,
        runtime = R
    )

    -- Python Markov regime switching model
    py_markov = node(
        command = <{
            import numpy as np
            from statsmodels.tsa.regime_switching.markov_regression import MarkovRegression
            rng = np.random.default_rng(42)
            y = rng.normal(size = 40)
            MarkovRegression(y, k_regimes = 2).fit(disp = False)
        }>,
        runtime = Python
    )

    -- Julia CategoricalArray (factor kind)
    jl_factor = node(
        command = <{
            using CategoricalArrays
            categorical(["low", "med", "high", "med", "low"])
        }>,
        runtime = Julia
    )

    -- Julia MultivariateStats MulticlassLDA
    jl_mlda = node(
        command = <{
            using MultivariateStats
            X = [1.0 2.0 1.1 1.9 5.0 5.2 4.9 5.1; 0.9 1.1 2.0 1.8 3.0 3.2 2.9 3.1]
            y = [1, 1, 1, 1, 2, 2, 2, 2]
            fit(MulticlassLDA, X, y; outdim = 1)
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Wave 2 Models Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta wave 2 facts.")

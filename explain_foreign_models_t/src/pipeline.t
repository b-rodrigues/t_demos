-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on regression model nodes from R and Python.
--
-- Each model result carries a build-time `meta` sidecar with model facts
-- (task, n_obs, n_features, target, formula, metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R linear model (mtcars, 32 obs, 2 features)
    r_fit = node(
        command = <{ lm(mpg ~ wt + hp, data = mtcars) }>,
        runtime = R
    )

    -- scikit-learn linear regression (3 obs, 1 feature)
    py_fit = node(
        command = <{
            from sklearn.linear_model import LinearRegression
            LinearRegression().fit([[1], [2], [3]], [2.0, 4.0, 6.0])
        }>,
        runtime = Python
    )

    -- R Cox proportional hazards (lung, survival)
    r_coxph = node(
        command = <{
            library(survival)
            coxph(Surv(time, status) ~ age + sex, data = lung)
        }>,
        runtime = R
    )
}

print("===============================================")
print("explain().foreign_meta Model Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta model facts.")

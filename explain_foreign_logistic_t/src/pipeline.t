-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on logistic regression nodes from R, Python, and Julia.
--
-- Each model result carries a build-time `meta` sidecar with model facts
-- (task, target, formula, metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R binomial glm (mtcars, 32 obs)
    r_glm = node(
        command = <{ glm(am ~ wt, data = mtcars, family = binomial) }>,
        runtime = R
    )

    -- scikit-learn logistic regression (2 classes)
    py_glm = node(
        command = <{
            from sklearn.linear_model import LogisticRegression
            LogisticRegression().fit([[1.0], [2.0], [3.0], [4.0]], [0, 0, 1, 1])
        }>,
        runtime = Python
    )

    -- GLM.jl binomial logit model
    jl_glm = node(
        command = <{
            using GLM
            df_glm = DataFrame(x = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], y = [0, 0, 0, 1, 1, 1])
            glm(@formula(y ~ x), df_glm, Binomial(), LogitLink())
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Logistic Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta logistic facts.")

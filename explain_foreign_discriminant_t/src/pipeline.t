-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on discriminant-analysis nodes from R and Python.
--
-- Each result carries a build-time `meta` sidecar with classification
-- facts (task, classes, features, fit metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R linear discriminant analysis (iris, 3 classes)
    r_lda = node(
        command = <{
            library(MASS)
            lda(Species ~ ., iris)
        }>,
        runtime = R
    )

    -- R ordered logistic regression (housing data)
    r_polr = node(
        command = <{
            library(MASS)
            polr(Sat ~ Infl + Type + Cont, data = housing, Hess = TRUE)
        }>,
        runtime = R
    )

    -- R multinomial regression (iris, 3 classes)
    r_multinom = node(
        command = <{
            library(nnet)
            multinom(Species ~ ., iris, trace = FALSE)
        }>,
        runtime = R
    )

    -- Gaussian mixture density estimation (2 components)
    py_gmm = node(
        command = <{
            from sklearn.mixture import GaussianMixture
            GaussianMixture(n_components = 2).fit([[1.0], [2.0], [3.0], [8.0], [9.0], [10.0]])
        }>,
        runtime = Python
    )

    -- Grid-searched logistic regression
    py_grid = node(
        command = <{
            from sklearn.linear_model import LogisticRegression
            from sklearn.model_selection import GridSearchCV
            X_grid = [[1.0], [2.0], [3.0], [4.0], [5.0], [6.0]]
            y_grid = [0, 0, 0, 1, 1, 1]
            GridSearchCV(LogisticRegression(), {"C": [0.1, 1.0]}, cv = 2).fit(X_grid, y_grid)
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta Discriminant Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta discriminant facts.")

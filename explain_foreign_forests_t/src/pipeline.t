-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on random forest nodes from R, Python, and Julia.
--
-- Each forest result carries a build-time `meta` sidecar with forest facts
-- (task, n_trees, n_obs, n_features, accuracy metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R random forest regression (mtcars, 50 trees)
    r_forest = node(
        command = <{
            library(randomForest)
            set.seed(1)
            randomForest(mpg ~ ., data = mtcars, ntree = 50)
        }>,
        runtime = R
    )

    -- scikit-learn random forest classifier (10 trees)
    py_forest = node(
        command = <{
            from sklearn.ensemble import RandomForestClassifier
            RandomForestClassifier(n_estimators = 10).fit([[1, 2], [2, 3], [3, 4], [4, 5]], [0, 0, 1, 1])
        }>,
        runtime = Python
    )

    -- DecisionTree.jl forest classifier (10 trees)
    jl_forest = node(
        command = <{
            using DecisionTree
            build_forest(["a", "a", "b", "b"], [1.0 2.0; 2.0 3.0; 3.0 4.0; 4.0 5.0], 2, 10)
        }>,
        runtime = Julia
    )

    -- DecisionTree.jl single tree
    jl_tree = node(
        command = <{
            using DecisionTree
            build_tree(["a", "a", "b", "b"], [1.0 2.0; 2.0 3.0; 3.0 4.0; 4.0 5.0])
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Forest Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta forest facts.")

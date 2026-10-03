-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on xgboost nodes from R and Python.
--
-- Each booster result carries a build-time `meta` sidecar with boosting
-- facts (task, n_rounds, n_features).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R xgboost booster (5 rounds, agaricus data)
    r_xgb = node(
        command = <{
            library(xgboost)
            data(agaricus.train)
            dm = xgb.DMatrix(agaricus.train$data, label = agaricus.train$label)
            xgb.train(list(objective = "binary:logistic", max_depth = 2), dm, nrounds = 5)
        }>,
        runtime = R
    )

    -- Python native xgboost booster (5 rounds)
    py_xgb = node(
        command = <{
            import xgboost as xgb
            dm = xgb.DMatrix([[1.0], [2.0], [3.0], [4.0]], label = [0.0, 0.0, 1.0, 1.0])
            xgb.train({"objective": "binary:logistic", "max_depth": 2}, dm, num_boost_round = 5)
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta XGBoost Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta boosting facts.")

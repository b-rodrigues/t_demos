-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on LightGBM booster nodes from R and Python.
--
-- Each booster result carries a build-time `meta` sidecar with boosting
-- facts (task, n_rounds, n_features).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R lightgbm booster (5 rounds, agaricus data)
    r_lgb = node(
        command = <{
            library(lightgbm)
            data(agaricus.train)
            dm = lgb.Dataset(agaricus.train$data, label = agaricus.train$label)
            lgb.train(list(objective = "binary", num_leaves = 4), dm, 5)
        }>,
        runtime = R
    )

    -- Python native lightgbm booster (5 rounds)
    py_lgb = node(
        command = <{
            import lightgbm as lgb
            from sklearn.datasets import make_classification
            X, y = make_classification(n_samples = 100, n_features = 4, random_state = 1)
            dm = lgb.Dataset(X, label = y)
            lgb.train({"objective": "binary", "num_leaves": 4}, dm, num_boost_round = 5)
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta LightGBM Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta boosting facts.")

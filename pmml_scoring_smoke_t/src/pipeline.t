-- pmml_scoring_smoke_t/src/pipeline.t
-- End-to-end smoke test for JPMML scoring.
--
-- The point of this demo is the plumbing, not model quality:
--   1. an R model (randomForest) and a Python model (statsmodels OLS) are
--      exported to PMML by their own runtimes;
--   2. a T node scores both PMML files with the JPMML evaluator JAR that
--      t-lang ships at <t-lang>/share/java/jpmml-evaluator.jar;
--   3. the T scores are compared with the native R and Python predictions.
--
-- Exporting the Python model exercises the shipped jpmml-statsmodels JAR,
-- scoring exercises the shipped jpmml-evaluator JAR, and both need a JVM.
-- Nothing is downloaded from Maven at build time.

scoring_data = rn(
    command = <{
        mtcars[, c("mpg", "wt", "hp", "disp")]
    }>,
    serializer = ^csv
)

rf_model_r = rn(
    command = <{
        library(randomForest)
        set.seed(42)
        randomForest(mpg ~ wt + hp + disp, data = scoring_data, ntree = 25)
    }>,
    deserializer = ^csv,
    serializer = ^pmml
)

rf_predictions_r = rn(
    command = <{
        library(randomForest)
        set.seed(42)
        model <- randomForest(mpg ~ wt + hp + disp, data = scoring_data, ntree = 25)
        data.frame(prediction = as.numeric(predict(model, scoring_data)))
    }>,
    deserializer = [ scoring_data: ^csv ],
    serializer = ^csv
)

ols_model_py = pyn(
    command = <{
        import pandas as pd
        import statsmodels.api as sm

        X = sm.add_constant(scoring_data[["wt", "hp", "disp"]])
        model = sm.OLS(scoring_data["mpg"], X).fit()

        # Metadata used by T's model summary.
        model.r2_ = model.rsquared
        model.nobs_ = int(model.nobs)
        model
    }>,
    deserializer = [ scoring_data: ^csv ],
    serializer = ^pmml
)

ols_predictions_py = pyn(
    command = <{
        import pandas as pd
        import statsmodels.api as sm

        X = sm.add_constant(scoring_data[["wt", "hp", "disp"]])
        model = sm.OLS(scoring_data["mpg"], X).fit()
        pd.DataFrame({"prediction": model.predict(X)})
    }>,
    deserializer = [ scoring_data: ^csv ],
    serializer = ^csv
)

verify_node = node(
    runtime = T,
    command = <{
        print("--- JPMML SCORING SMOKE TEST ---")
        print("Rows to score:")
        print(nrow(scoring_data))

        pred_r = predict(scoring_data, rf_model_r)
        pred_py = predict(scoring_data, ols_model_py)

        check(expect_nrow(scoring_data, 32))
        check(expect_length(pred_r, 32))
        check(expect_length(pred_py, 32))
        check(expect_no_na(pred_r))
        check(expect_no_na(pred_py))

        native_r = pull(rf_predictions_r, "prediction")
        native_py = pull(ols_predictions_py, "prediction")

        diff_r = (native_r .- pred_r) |> abs() |> max(na_rm = true)
        diff_py = (native_py .- pred_py) |> abs() |> max(na_rm = true)

        print("Max |R native - T JPMML| for randomForest:")
        print(diff_r)
        print("Max |Python native - T JPMML| for statsmodels OLS:")
        print(diff_py)

        check(diff_r < 0.000001)
        check(diff_py < 0.000001)

        "JPMML scores match the native R and Python predictions"
    }>,
    deserializer = [
        scoring_data: ^csv,
        rf_model_r: ^pmml,
        ols_model_py: ^pmml,
        rf_predictions_r: ^csv,
        ols_predictions_py: ^csv
    ]
)

p = pipeline {
    scoring_data = scoring_data
    rf_model_r = rf_model_r
    rf_predictions_r = rf_predictions_r
    ols_model_py = ols_model_py
    ols_predictions_py = ols_predictions_py
    verify_node = verify_node
}

build_pipeline(p, verbose = 1)

check(is_error(read_node(p.scoring_data)) == false)
check(is_error(read_node(p.rf_model_r)) == false)
check(is_error(read_node(p.ols_model_py)) == false)
check(is_error(read_node(p.verify_node)) == false)

print(read_node(p.verify_node))
print("pmml_scoring_smoke_t: all assertions passed")

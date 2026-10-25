-- pmml_scoring_smoke_t/src/verify.t
-- Second half of the smoke test: score the built PMML artifacts in a fresh
-- T process from the project shell, not inside a pipeline node.
--
-- This is the ad-hoc `predict()` path. It reads T_JPMML_EVALUATOR_JAR from
-- the generated project shell and finds the JVM on PATH (the `jre` entry in
-- [additional-tools]); a pipeline node gets both from its derivation.
--
-- Run after the pipeline has been built:  t run --unsafe src/verify.t

t_make()

scoring = read_node(p.scoring_data)
model_r = read_node(p.rf_model_r)
model_py = read_node(p.ols_model_py)

pred_r = predict(scoring, model_r)
pred_py = predict(scoring, model_py)

native_r = pull(read_node(p.rf_predictions_r), "prediction")
native_py = pull(read_node(p.ols_predictions_py), "prediction")

diff_r = (native_r .- pred_r) |> abs() |> max(na_rm = true)
diff_py = (native_py .- pred_py) |> abs() |> max(na_rm = true)

print("Max |R native - T JPMML| in a fresh process:")
print(diff_r)
print("Max |Python native - T JPMML| in a fresh process:")
print(diff_py)

ok_r = is_error(pred_r) == false && is_error(diff_r) == false && diff_r < 0.000001
ok_py = is_error(pred_py) == false && is_error(diff_py) == false && diff_py < 0.000001

-- `check()` does not stop a script, so the last value is an explicit error
-- when parity breaks; `t run` exits non-zero on an error result.
if (ok_r && ok_py) {
    print("Ad-hoc JPMML scoring matches the native predictions")
} else {
    error("Ad-hoc JPMML scoring does not match the native predictions. See the diffs printed above.")
}

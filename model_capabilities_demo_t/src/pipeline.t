p = pipeline {
    -- 1. Data Loading (Local CSV)
    df = node(
        command = read_csv("src/mtcars.csv"),
        serializer = ^csv
    )

    -- 2. Native Model Fitting
    model_lm = node(
        command = lm(mpg ~ wt + hp, data: df),
        deserializer = [df: ^csv]
    )

    model_nested = node(
        command = lm(mpg ~ wt, data: df),
        deserializer = [df: ^csv]
    )

    -- 3. Model Inspection (JSON)
    node_summary = node(summary(model_lm)._tidy_df, deserializer: [model_lm: ^default], serializer: ^json)
    node_coef    = node(coef(model_lm), deserializer: [model_lm: ^default], serializer: ^json)
    node_stats   = node(fit_stats(model_lm), deserializer: [model_lm: ^default], serializer: ^json)
    node_ci      = node(conf_int(model_lm, 0.95), deserializer: [model_lm: ^default], serializer: ^json)
    node_vcov    = node(vcov(model_lm), deserializer: [model_lm: ^default], serializer: ^json)

    -- 4. Diagnostics & Prediction (JSON)
    node_diag    = node(add_diagnostics(df, model_lm), deserializer: [df: ^csv, model_lm: ^default], serializer: ^json)
    node_resid   = node(residuals(df, model_lm), deserializer: [df: ^csv, model_lm: ^default], serializer: ^json)
    node_pred    = node(predict(df, model_lm), deserializer: [df: ^csv, model_lm: ^default], serializer: ^json)

    -- 5. Comparison & Hypothesis Testing (JSON)
    node_compare = node(compare(model_nested, model_lm), deserializer: [model_nested: ^default, model_lm: ^default], serializer: ^json)
    node_anova   = node(anova(model_nested, model_lm), deserializer: [model_nested: ^default, model_lm: ^default], serializer: ^json)
    node_wald    = node(wald_test(model_lm, ["wt", "hp"]), deserializer: [model_lm: ^default], serializer: ^json)
}

-- Execute build
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("[ERROR]", error_message(res))
    exit(1)
}

print("==================================================")
print("T-LANG MODEL CAPABILITIES DEMO RESULTS")
print("==================================================")
print("")
print("1. Coefficients (from Summary):")
print(read_node(p, "node_summary"))
print("")
print("2. Fit Statistics:")
print(read_node(p, "node_stats"))
print("")
print("3. ANOVA (Nested Models):")
print(read_node(p, "node_anova"))
print("")
print("4. Wald Test (Joint wt, hp):")
print(read_node(p, "node_wald"))
print("")
print("5. Diagnostic Augmentation:")
print(read_node(p, "node_diag"))
print("")
print("6. Confidence Intervals:")
print(read_node(p, "node_ci"))

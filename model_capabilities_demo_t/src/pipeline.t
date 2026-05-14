p = pipeline {
    -- ── 1. Data Generation ──────────────────────────────────────────────────
    df = node(
        command = <{
            import numpy as np
            import pandas as pd
            np.random.seed(42)
            n = 32
            x1 = np.random.normal(5, 2, n)
            x2 = np.random.normal(10, 5, n)
            # Linear relationship with noise
            y = 2.5 + 1.2 * x1 - 0.4 * x2 + np.random.normal(0, 1, n)
            
            # Binary target for GLM/Logistic comparison
            y_bin = (y > np.median(y)).astype(int)
            
            pd.DataFrame({"y": y, "y_bin": y_bin, "x1": x1, "x2": x2})
        }>,
        runtime    = Python,
        serializer = ^csv
    )

    -- ── 2. Native Model Fitting: lm() ────────────────────────────────────────
    model_lm = node(
        command = lm(df, y ~ x1 + x2),
        deserializer = [df: ^csv]
    )

    -- ── 3. Model Inspection: summary() ───────────────────────────────────────
    node_summary = node(
        command = summary(model_lm)._tidy_df,
        deserializer = [model_lm: ^default]
    )

    -- ── 4. Model Inspection: coef() ──────────────────────────────────────────
    node_coef = node(
        command = coef(model_lm),
        deserializer = [model_lm: ^default]
    )

    -- ── 5. Model Inspection: fit_stats() ─────────────────────────────────────
    node_stats = node(
        command = fit_stats(model_lm),
        deserializer = [model_lm: ^default]
    )

    -- ── 6. Model Inspection: conf_int() ──────────────────────────────────────
    node_ci = node(
        command = conf_int(model_lm, level: 0.95),
        deserializer = [model_lm: ^default]
    )

    -- ── 7. Model Diagnostics: add_diagnostics() ──────────────────────────────
    node_diag = node(
        command = add_diagnostics(df, model_lm),
        deserializer = [df: ^csv, model_lm: ^default]
    )

    -- ── 8. Model Diagnostics: residuals() ────────────────────────────────────
    node_resid = node(
        command = residuals(df, model_lm),
        deserializer = [df: ^csv, model_lm: ^default]
    )

    -- ── 9. Prediction: predict() ─────────────────────────────────────────────
    node_pred = node(
        command = predict(df, model_lm),
        deserializer = [df: ^csv, model_lm: ^default]
    )

    -- ── 10. Model Comparison: compare() and anova() ──────────────────────────
    model_nested = node(
        command = lm(df, y ~ x1),
        deserializer = [df: ^csv]
    )

    node_compare = node(
        command = compare(model_nested, model_lm),
        deserializer = [model_nested: ^default, model_lm: ^default]
    )

    node_anova = node(
        command = anova(model_nested, model_lm),
        deserializer = [model_nested: ^default, model_lm: ^default]
    )

    -- ── 11. Hypothesis Testing: wald_test() and vcov() ───────────────────────
    node_wald = node(
        command = wald_test(model_lm, terms: ["x1", "x2"]),
        deserializer = [model_lm: ^default]
    )

    node_vcov = node(
        command = vcov(model_lm),
        deserializer = [model_lm: ^default]
    )

    -- ── 12. Polyglot Model: GLM via R (PMML) ─────────────────────────────────
    model_r_pmml = rn(
        command = <{
            glm(y_bin ~ x1 + x2, data = df, family = binomial())
        }>,
        deserializer = [df: ^csv],
        serializer = ^pmml
    )

    -- Show that T functions work on PMML models too
    node_pmml_summary = node(
        command = summary(model_r_pmml)._tidy_df,
        deserializer = [model_r_pmml: ^pmml]
    )
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
print("1. LM Coefficients (Native):")
print(read_node(p, "node_coef"))
print("")
print("2. Model Fit Statistics:")
print(read_node(p, "node_stats"))
print("")
print("3. ANOVA (Nested Models):")
print(read_node(p, "node_anova"))
print("")
print("4. Wald Test (Joint Significance of x1, x2):")
print(read_node(p, "node_wald"))
print("")
print("5. PMML Model Summary (from R):")
print(read_node(p, "node_pmml_summary"))

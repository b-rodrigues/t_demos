import stats
import dataframe

p = pipeline {
    data_node = node(
        command = <{
            library(faraway)
            data(hsb)
            # Select relevant columns and handle factors
            # We convert binary target to integer for easier comparison
            hsb$target <- as.integer(hsb$prog == "academic")
            hsb$ses <- as.character(hsb$ses)
            hsb$schtyp <- as.character(hsb$schtyp)
            hsb
        }>,
        runtime = R,
        serializer = ^arrow
    );

    r_model_node = node(
        command = <{
            # Logistic regression as in the article
            # Formula: target ~ ses + schtyp + read + write + science + socst
            data_node$target <- as.factor(data_node$target)
            data_node$ses <- as.factor(data_node$ses)
            data_node$schtyp <- as.factor(data_node$schtyp)
            glm(target ~ ses + schtyp + read + write + science + socst, 
                family = binomial(link = "logit"), 
                data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^arrow
    );

    py_model_node = node(
        command = <{
import statsmodels.api as sm
import pandas as pd
# Manual dummification to ensure JPMML compatibility
# We match R's specific dummies seen in previous summaries: seslow, sesmiddle, schtyppublic
data_node['ses_low'] = (data_node['ses'] == 'low').astype(float)
data_node['ses_middle'] = (data_node['ses'] == 'middle').astype(float)
data_node['schtyp_public'] = (data_node['schtyp'] == 'public').astype(float)

X = data_node[['ses_low', 'ses_middle', 'schtyp_public', 'read', 'write', 'science', 'socst']]
X = sm.add_constant(X)
y = data_node['target']
# jpmml-statsmodels serialization
py_model_node = sm.GLM(y, X, family=sm.families.Binomial()).fit()
        }>,
        runtime = Python,
        serializer = ^pmml,
        deserializer = ^arrow
    )
}

print("Building HSB (Binary Logistic) pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.")
    
    df = read_node("data_node")
    r_model = read_node("r_model_node")
    py_model = read_node("py_model_node")
    
    print("\n--- R Model Summary ---")
    s_r = summary(r_model)
    print(s_r)
    
    print("\n--- Python Model Summary ---")
    s_py = summary(py_model)
    print(s_py)
    
    print("\nComparing R and Python coefficients...")
    -- Both should have seslow, sesmiddle, schtyppublic etc.
    -- We can compare them by joining the tidy dataframes
    
    print("\nR Coefficients:")
    print(r_model.coefficients)
    
    print("\nPython Coefficients:")
    print(py_model.coefficients)
    
    print("\nComputing predictions in T (R Model)...")
    preds_r = predict(df, r_model)
    
    print("Computing predictions in T (Python Model)...")
    -- Prepare data for Python PMML prediction (matching manual dummification)
    df1 = mutate(df, ses_low = ifelse($ses .== "low", 1.0, 0.0))
    df2 = mutate(df1, ses_middle = ifelse($ses .== "middle", 1.0, 0.0))
    df3 = mutate(df2, schtyp_public = ifelse($schtyp .== "public", 1.0, 0.0))
    df4 = mutate(df3, read = $read)
    df5 = mutate(df4, write = $write)
    df6 = mutate(df5, science = $science)
    df7 = mutate(df6, socst = $socst)
    df_py = mutate(df7, const = 1.0)
    preds_py = predict(df_py, py_model)
    
    if (is_error(preds_py)) {
        print("PYTHON PREDS ERROR:")
        print(preds_py)
    }
    
    p_r = pull(preds_r, "probability(1)")
    p_py = pull(preds_py, "probability(1)")

    mae = mean(abs(p_r .- p_py))
    print("\nMAE between R and Python probabilities in T:")
    print(mae)
    
    if (!(is_error(mae)) && mae < 0.005) {
        print("SUCCESS: Predictions from both models match perfectly in T!")
    } else {
        print("WARNING: Significant difference in predictions.")
    }
}

-- Source: https://www.science.smith.edu/~jcrouser/SDS293/labs/2016/
import stats
import dataframe

p = pipeline {
    boston_raw = node(
        command = <{ read_csv("data/Boston.csv") }>,
        serializer = ^arrow
    );

    data_node = node(
        command = <{
            # boston_raw is provided as an R data.frame
            df <- boston_raw[, -1]
            df
        }>,
        runtime = R,
        serializer = ^arrow,
        deserializer = ^arrow -- Added explicit deserializer for T -> R
    );

    r_model = node(
        command = <{
            # medv ~ lstat
            lm(medv ~ lstat, data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^arrow
    );

    py_model = node(
        command = <{
import statsmodels.api as sm
import patsy
# medv ~ lstat
y, X = patsy.dmatrices('medv ~ lstat', data_node, return_type='dataframe')
y = y.iloc[:, 0]
py_model = sm.OLS(y, X).fit()
        }>,
        runtime = Python,
        serializer = ^pmml,
        deserializer = ^arrow
    )
}

print("Building Lab 2 (Boston Linear Regression) pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.")
    
    df = read_node(p.data_node)
    m_r = read_node(p.r_model)
    m_py = read_node(p.py_model)
    
    print("\n--- R Model Summary ---")
    print(summary(m_r))
    
    print("\n--- Python Model Summary ---")
    print(summary(m_py))
    
    print("\nComparing coefficients...")
    print("R Coefficients:")
    print(m_r.coefficients)
    print("Python Coefficients:")
    print(m_py.coefficients)
    
    print("\nComputing predictions in T...")
    preds_r = predict(df, m_r)
    preds_py = predict(df, m_py)
    
    mae = mean(abs(preds_r .- preds_py))
    print("MAE (R vs Py) in T:")
    print(mae)
    
    if (mae < 0.001) {
        print("SUCCESS: Predictions match!")
    } else {
        print("WARNING: Predictions differ.")
    }
    
    -- Node correctness assertions
    assert(type(read_node(p.data_node).error) == "NA", "data_node should succeed")
    assert(type(read_node(p.r_model).error) == "NA", "r_model should succeed")
    assert(type(read_node(p.py_model).error) == "NA", "py_model should succeed")
    
    print("✓ isl_lab2_boston_t: all assertions passed")
}

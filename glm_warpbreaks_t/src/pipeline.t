import stats
import dataframe
import colcraft

p = pipeline {
    data_node = node(
        command = <{
            data(warpbreaks)
            warpbreaks$wool <- as.character(warpbreaks$wool)
            warpbreaks$tension <- as.character(warpbreaks$tension)
            warpbreaks
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- Poisson model with interaction between wool and tension
    r_poisson = node(
        command = <{
            data_node$wool <- as.factor(data_node$wool)
            data_node$tension <- as.factor(data_node$tension)
            glm(breaks ~ wool * tension, family = "poisson", data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^arrow
    );

    -- Negative Binomial model for comparison (often better for count data)
    r_nb = node(
        command = <{
            library(MASS)
            data_node$wool <- as.factor(data_node$wool)
            data_node$tension <- as.factor(data_node$tension)
            glm.nb(breaks ~ wool * tension, data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^arrow
    );

    -- Python Poisson model with formula
    py_poisson = node(
        command = <{
import statsmodels.api as sm
import pandas as pd
# Manual dummification to ensure JPMML compatibility across runtimes
data_node['wool_B'] = (data_node['wool'] == 'B').astype(float)
data_node['tension_M'] = (data_node['tension'] == 'M').astype(float)
data_node['tension_L'] = (data_node['tension'] == 'L').astype(float)
data_node['woolB_tensionM'] = data_node['wool_B'] * data_node['tension_M']
data_node['woolB_tensionL'] = data_node['wool_B'] * data_node['tension_L']

X = data_node[['wool_B', 'tension_M', 'tension_L', 'woolB_tensionM', 'woolB_tensionL']]
X = sm.add_constant(X)
y = data_node['breaks']
# jpmml-statsmodels serialization
py_poisson = sm.GLM(y, X, family=sm.families.Poisson()).fit()
        }>,
        runtime = Python,
        serializer = ^pmml,
        deserializer = ^arrow
    )
}

print("Building Warpbreaks Pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed.")
    print(res)
} else {
    print("Build successful.")
    df = read_node("data_node")
    m_p_r  = read_node("r_poisson")
    m_nb_r = read_node("r_nb")
    m_p_py = read_node("py_poisson")
    
    print("\n--- Warpbreaks Poisson (R) Summary ---")
    print(summary(m_p_r))
    
    print("\n--- Warpbreaks NegBinom (R) Summary ---")
    print(summary(m_nb_r))

    print("\n--- Warpbreaks Poisson (Python) Summary ---")
    print(summary(m_p_py))
    print("\nComputing predictions in T...")
    preds_r = predict(df, m_p_r)
    
    -- Prepare data for Python PMML prediction (matching manual dummification)
    WB_DF_PY = df |> mutate(
        wool_B = ifelse($wool .== "B", 1.0, 0.0),
        tension_M = ifelse($tension .== "M", 1.0, 0.0),
        tension_L = ifelse($tension .== "L", 1.0, 0.0),
        woolB_tensionM = $wool_B .* $tension_M,
        woolB_tensionL = $wool_B .* $tension_L,
        const = 1.0
    )

    WB_PREDS_PY = predict(WB_DF_PY, m_p_py)
    
    if (is_error(WB_PREDS_PY)) {
        print("PYTHON PREDS ERROR:")
        print(WB_PREDS_PY)
    }
    
    mae = mean(abs(preds_r .- WB_PREDS_PY))
    print("\nPoisson MAE (R vs Py) in T:")
    print(mae)
    
    if (!(is_error(mae)) && mae < 0.005) {
        print("SUCCESS: Warpbreaks predictions match!")
    } else {
        print("WARNING: Warpbreaks predictions differ.")
    }
}

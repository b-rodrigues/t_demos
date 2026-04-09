-- pmml_interchange_demo.t
-- Demonstrating standardized PMML interchange across R, Python, and T
-- with JPMML as the canonical scoring authority.

data_node = node(
    command = read_csv("data/mtcars.csv", separator: "|") |>
      mutate($cyl = factor($cyl), $am = factor($am)),
    serializer = ^csv
)

-- 1. Linear Model in R (with Categorical Factors)
model_r_node = node(
    command = <{
        # In R: mpg predicted by weight, horsepower, and cylinder (as factor)
        lm(mpg ~ wt + hp + cyl, data = data_node)
    }>,
    runtime = "R",
    deserializer = ^csv,
    serializer = ^pmml
)

-- 2. Random Forest in R (Testing Tree-based Parity)
rf_r_node = node(
    command = <{
        # In R: Random Forest for regression
        library(randomForest)
        randomForest(mpg ~ wt + hp + disp, data = data_node, ntree = 10)
    }>,
    runtime = "R",
    deserializer = ^csv,
    serializer = ^pmml
)

-- 3. Scikit-Learn Linear Model in Python
model_py_node = node(
    command = <{
# In Python: scikit-learn OLS
import pandas as pd
from sklearn.linear_model import LinearRegression

X = data_node[["wt", "hp"]]
y = data_node["mpg"]
model = LinearRegression().fit(X, y)

# Metadata for T-Lang bridge (Phase 4 GLM support)
model.r2_ = model.score(X, y)
model.nobs_ = len(y)
model
    }>,
    runtime = "Python",
    deserializer = ^csv,
    serializer = ^pmml
)

-- 4. T-Lang Native Verification Node
-- This node runs in T and performs scoring using our standardized JPMML bridge.
verify_node = node(
    command = <{
        print("--- PHASE 2: AUTHORITY PIVOT VERIFICATION ---")

        -- Score R Linear Model (Categorical factors resolved by JPMML)
        p_lm_r = predict(data_node, model_r_node)
        print("R Linear Model Predictions (first 5):")
        print(head(p_lm_r))

        -- Score R Random Forest (Complex trees resolved by JPMML)
        p_rf_r = predict(data_node, rf_r_node)
        print("R Random Forest Predictions (first 5):")
        print(head(p_rf_r))

        -- Score Python Model
        p_lm_py = predict(data_node, model_py_node)
        print("Python model predictions in T:")
        print(head(p_lm_py))

        print("--- PHASE 4: METADATA & VALIDATION ---")
        print("R Model Summary:")
        print(summary(model_r_node))

        print("Python Model R-Squared:")
        print(model_py_node.r_squared)

        "Verification complete"
    }>,
    runtime = "T",
    deserializer = [
        data_node: ^csv,
        model_r_node: ^pmml,
        rf_r_node: ^pmml,
        model_py_node: ^pmml
    ]
)

p = pipeline {
    data_node = data_node
    model_r_node = model_r_node
    rf_r_node = rf_r_node
    model_py_node = model_py_node
    verify_node = verify_node
}

build_pipeline(p, verbose=1)

print("Pipeline defined successfully.")

import stats
import dataframe

p = pipeline {
    data_node = node(
        command = <{
            data(discoveries)
            disc <- data.frame(count = as.numeric(discoveries),
                               year = seq(0, (length(discoveries) - 1)))
            disc$yearSqr <- disc$year^2
            disc
        }>,
        runtime = R,
        serializer = ^ipc
    );

    poisson_r = node(
        command = <{
            glm(count ~ year + yearSqr, family = "poisson", data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^ipc
    );

    nb_r = node(
        command = <{
            library(MASS)
            # Use glm.nb for Negative Binomial
            glm.nb(count ~ year + yearSqr, data = data_node)
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^ipc
    );

    poisson_py = node(
        command = <{
import statsmodels.api as sm
import os
y = data_node['count']
X = sm.add_constant(data_node[['year', 'yearSqr']])
poisson_py = sm.GLM(y, X, family=sm.families.Poisson()).fit()
        }>,
        runtime = Python,
        serializer = ^pmml,
        deserializer = ^ipc
    )
}

print("Building Discoveries (Count Response) pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.")

    df = read_node(p.data_node)
    p_r = read_node(p.poisson_r)
    p_py = read_node(p.poisson_py)
    nb_r = read_node(p.nb_r)
    
    print("\n--- Poisson (R) Summary ---")
    print(summary(p_r))
    
    print("\n--- Poisson (Python) Summary ---")
    print(summary(p_py))

    print("\n--- NegBinomial (R) Summary ---")
    print(summary(nb_r))

    print("\nComputing predictions in T...")
    -- All predictors are numeric (year, yearSqr, const)
    -- T's predict() expects 'const' if statsmodels used sm.add_constant
    -- statsmodels uses 'const' as intercept name in PMML
    -- r2pmml uses '(Intercept)'
    
    -- T's predict() handles standard intercept names: (Intercept), Intercept, const
    
    print("R Coefficients:")
    print(p_r.coefficients)
    
    print("Python Coefficients:")
    print(p_py.coefficients)
    
    preds_p_r = predict(df, p_r)
    preds_p_py = predict(df, p_py)
    
    preds_nb_r = predict(df, nb_r)
    
    mae_p = mean(abs(preds_p_r .- preds_p_py))
    
    print("\nPoisson MAE (R vs Py) in T:")
    print(mae_p)
    
    check(expect_lt(mae_p, 0.1))
    
    -- Node correctness assertions
    r_data = read_node(p.data_node)
    check(is_error(r_data) == false)
    check(is_error(read_node(p.poisson_r)) == false)
    check(is_error(read_node(p.nb_r)) == false)
    check(is_error(read_node(p.poisson_py)) == false)
    
    print("✓ glm_discoveries_t: all assertions passed")
}

-- pmml_julia_r_interop.t
-- Demonstrating GLM training in R and Julia with PMML interchange
-- and cross-language prediction parity using the JPMML bridge.

data_node = node(
    command = read_csv("data/mtcars.csv", separator = "|"),
    runtime = T,
    serializer = ^csv
)

-- 1. Train GLM in R and export as PMML
model_r = rn(
    command = <{
        # In R: mpg ~ wt + hp
        model <- glm(mpg ~ wt + hp, data = data_node)
        model
    }>,
    deserializer = ^csv,
    serializer = ^pmml
)

-- 2. Train GLM in Julia and export as PMML (using our new native exporter)
model_jl = jln(
    command = <{
        # In Julia: mpg ~ wt + hp
        model = lm(@formula(mpg ~ wt + hp), data_node)
        model
    }>,
    deserializer = ^csv,
    serializer = ^pmml
)

-- 3. Native R Prediction (Baseline)
predict_r_native = rn(
    command = <{
        model <- glm(mpg ~ wt + hp, data = data_node)
        data.frame(prediction = predict(model, data_node))
    }>,
    deserializer = ^csv,
    serializer = ^csv
)

-- 4. Native Julia Prediction (Baseline)
predict_jl_native = jln(
    command = <{
        model = lm(@formula(mpg ~ wt + hp), data_node)
        DataFrame(prediction = predict(model, data_node))
    }>,
    deserializer = ^csv,
    serializer = ^csv
)

-- 5. Julia scoring R model via PMML
predict_jl_pmml_r = jl_node(
    command = <{
        # This uses the JPMML bridge in Julia
        res = predict(model_r, data_node)
        # JPMML output columns can be named after the target field
        rename!(res, names(res)[1] => :prediction)
        res
    }>,
    deserializer = [ model_r: ^pmml, data_node: ^csv ],
    serializer = ^csv
)

-- 6. T-Lang scoring both models via PMML
verify_node = node(
    command = <{
        print("--- PHASE 1: T-LANG NATIVE SCORING ---")
        
        -- Score R Model in T
        p_r = predict(data_node, model_r)
        print("T-Lang scoring R Model (first 3):")
        print(head(p_r, n = 3))

        -- Score Julia Model in T
        p_jl = predict(data_node, model_jl)
        print("T-Lang scoring Julia Model (first 3):")
        print(head(p_jl, n = 3))

        print("--- PHASE 2: CROSS-LANGUAGE COMPARISON ---")
        
        -- Compare R native vs T-Lang scoring of R model
        v_r_native = pull(predict_r_native, $prediction)
        diff_r = max(abs(v_r_native .- p_r))
        print("Max absolute difference (R native vs T-Lang R-Model):")
        print(diff_r)
        
        -- Compare Julia native vs T-Lang scoring of Julia model
        v_jl_native = pull(predict_jl_native, $prediction)
        diff_jl = max(abs(v_jl_native .- p_jl))
        print("Max absolute difference (Julia native vs T-Lang Julia-Model):")
        print(diff_jl)
        
        -- Compare Julia scoring of R model vs R native
        v_jl_pmml_r = pull(predict_jl_pmml_r, $prediction)
        diff_jl_r = max(abs(v_jl_pmml_r .- v_r_native))
        print("Max absolute difference (Julia PMML-R vs R native):")
        print(diff_jl_r)
        
        "Verification complete"
    }>,
    runtime = T,
    deserializer = [
        data_node: ^csv,
        model_r: ^pmml,
        model_jl: ^pmml,
        predict_r_native: ^csv,
        predict_jl_native: ^csv,
        predict_jl_pmml_r: ^csv
    ]
)

p = pipeline {
    data_node = data_node
    model_r = model_r
    model_jl = model_jl
    predict_r_native = predict_r_native
    predict_jl_native = predict_jl_native
    predict_jl_pmml_r = predict_jl_pmml_r
    verify_node = verify_node
}

build_pipeline(p, verbose = 1)

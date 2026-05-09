-- pmml_julia_rf_stress_t/src/pipeline.t
-- Stress testing Julia PMML scoring with a larger synthetic regression workload.

training_data = rn(
    command = <{
        set.seed(42)
        n <- 2500
        df <- data.frame(
            x1 = runif(n, -3, 3),
            x2 = rnorm(n),
            x3 = sample(0:1, n, replace = TRUE),
            x4 = runif(n, 0, 10)
        )
        df$y <- 5 + 1.5 * df$x1 - 0.8 * df$x2 + 2.2 * df$x3 + sin(df$x4) + rnorm(n, sd = 0.15)
        df
    }>,
    serializer = ^csv
)

scoring_data = rn(
    command = <{
        set.seed(314)
        n <- 20000
        df <- data.frame(
            x1 = runif(n, -3, 3),
            x2 = rnorm(n),
            x3 = sample(0:1, n, replace = TRUE),
            x4 = runif(n, 0, 10)
        )
        df$y <- 5 + 1.5 * df$x1 - 0.8 * df$x2 + 2.2 * df$x3 + sin(df$x4)
        df
    }>,
    serializer = ^csv
)

rf_model_r = rn(
    command = <{
        library(randomForest)
        set.seed(42)
        randomForest(y ~ x1 + x2 + x3 + x4, data = training_data, ntree = 40, mtry = 2)
    }>,
    deserializer = ^csv,
    serializer = ^pmml
)

glm_model_jl = jln(
    command = <{
        model = lm(@formula(y ~ x1 + x2 + x3 + x4), training_data)
        model
    }>,
    deserializer = [ training_data: ^csv ],
    serializer = ^pmml
)

rf_predict_r_native = rn(
    command = <{
        library(randomForest)
        set.seed(42)
        model <- randomForest(y ~ x1 + x2 + x3 + x4, data = training_data, ntree = 40, mtry = 2)
        data.frame(prediction = as.numeric(predict(model, scoring_data)))
    }>,
    deserializer = [ training_data: ^csv, scoring_data: ^csv ],
    serializer = ^csv
)

rf_predict_jl_pmml = node(
    runtime = "Julia",
    command = <{
        res = predict(rf_model_r, scoring_data)
        rename!(res, 1 => :prediction)
        res
    }>,
    deserializer = [ rf_model_r: ^pmml, scoring_data: ^csv ],
    serializer = ^csv
)

glm_predict_jl_native = node(
    runtime = "Julia",
    command = <{
        model = lm(@formula(y ~ x1 + x2 + x3 + x4), training_data)
        DataFrame(prediction = predict(model, scoring_data))
    }>,
    deserializer = [ training_data: ^csv, scoring_data: ^csv ],
    serializer = ^csv
)

verify_node = node(
    command = <{
        print("--- PMML JULIA RANDOM FOREST STRESS TEST ---")

        rf_t = predict(scoring_data, rf_model_r)
        glm_t = predict(scoring_data, glm_model_jl)

        rf_r = pull(rf_predict_r_native, "prediction")
        rf_jl = pull(rf_predict_jl_pmml, "prediction")
        glm_jl = pull(glm_predict_jl_native, "prediction")

        rf_diff_t = (rf_r .- rf_t) |> abs() |> max(na_rm = true)
        rf_diff_jl = (rf_r .- rf_jl) |> abs() |> max(na_rm = true)
        glm_diff_t = (glm_jl .- glm_t) |> abs() |> max(na_rm = true)

        print("Rows scored:")
        print(nrow(scoring_data))
        print("Max RF difference (R native vs T PMML):")
        print(rf_diff_t)
        print("Max RF difference (R native vs Julia PMML):")
        print(rf_diff_jl)
        print("Max GLM difference (Julia native vs T PMML):")
        print(glm_diff_t)

        assert(nrow(scoring_data) == 20000, "Stress dataset should keep 20000 rows")
        assert(rf_diff_t < 0.000001, "T PMML random forest scoring should match R")
        assert(rf_diff_jl < 0.000001, "Julia PMML random forest scoring should match R")
        assert(glm_diff_t < 0.00000001, "T PMML GLM scoring should match Julia")

        "Stress verification complete"
    }>,
    runtime = T,
    deserializer = [
        scoring_data: ^csv,
        rf_model_r: ^pmml,
        glm_model_jl: ^pmml,
        rf_predict_r_native: ^csv,
        rf_predict_jl_pmml: ^csv,
        glm_predict_jl_native: ^csv
    ]
)

p = pipeline {
    training_data = training_data
    scoring_data = scoring_data
    rf_model_r = rf_model_r
    glm_model_jl = glm_model_jl
    rf_predict_r_native = rf_predict_r_native
    rf_predict_jl_pmml = rf_predict_jl_pmml
    glm_predict_jl_native = glm_predict_jl_native
    verify_node = verify_node
}

build_pipeline(p, verbose = 1)

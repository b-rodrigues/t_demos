import dataframe
import colcraft
import stats
import "src/features.t"

p = pipeline {
    -- 1. Data Generation (R)
    raw_data = node(runtime = R, command = <{
        library(readr)
        set.seed(123)
        df <- data.frame(
            id = 1:50,
            income = runif(50, 20000, 100000),
            age = runif(50, 20, 70),
            category = sample(c("A", "B"), 50, replace = TRUE),
            stringsAsFactors = FALSE
        )
        df
    }>, serializer = ^ipc)

    -- 2. Dynamic Feature Engineering (T)
    features_t = node(raw_data, command = <{
        import "src/features.t"
        -- We define the transformations as a list of dictionaries
        feature_specs = [
            [col: "income", type: "log", suffix: "_log"],
            [col: "income", type: "scale", suffix: "_z"],
            [col: "age", type: "sqrt", suffix: "_sqrt"]
        ]
        -- Apply the transformations using our T-Lang function
        engineer_features(raw_data, feature_specs)
    }>, runtime = T, deserializer = ^ipc, serializer = ^ipc)

    -- 3. Reference Implementation (R)
    features_r = node(raw_data, command = <{
        library(dplyr)
        raw_data %>%
            mutate(
                income_log = log(income),
                income_z = (income - mean(income)) / sd(income),
                age_sqrt = sqrt(age)
            )
    }>, runtime = R, deserializer = ^ipc, serializer = ^ipc)

    -- 4. Validation
    validation = node(features_t, features_r, command = <{
        -- Check column names
        t_cols = colnames(features_t)
        r_cols = colnames(features_r)
        assert(t_cols == r_cols, "Column names mismatch")
        
        -- Check values with tolerance
        check_feature = \(name) {
            v_t = get(features_t, name)
            v_r = get(features_r, name)
            diff = sum(abs(v_t - v_r))
            assert(diff < 0.000000001, str_join(["Mismatch in feature: ", name]))
        }
        
        check_feature("income_log")
        check_feature("income_z")
        check_feature("age_sqrt")
        
        "Validation Successful: T-Lang dynamic features match R reference!"
    }>, runtime = T, deserializer = [features_t: ^ipc, features_r: ^ipc])
}

print("==================================================")
print("T-LANG DEMO: DYNAMIC FEATURE ENGINEERING")
print("==================================================")
print("This pipeline demonstrates how T-Lang's metaprogramming")
print("and recursion can be used to generate features based")
print("on a configuration list.")

populate_pipeline(p, build = true)

print("\nPipeline Summary:")
print(pipeline_summary(p))

res = read_node(p.validation)
if (is_error(res.value)) {
    print("\nValidation Failed:")
    print(explain(res.value))
} else {
    print("\nValidation Result:")
    print(res.value)
}

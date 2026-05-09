import dataframe
import colcraft
import base
import chrono
import stats

p = pipeline {
    -- R node generating "dirty" data that violates several constraints
    raw_data = node(
        command = <{
            df <- data.frame(
                id = 1:5,
                age = c(25, -5, 30, 40, 22),              # Violation: age < 0
                score = c(85, 90, 150, 70, 60),           # Violation: score > 100
                signup_date = c("2023-01-01", "2023-01-10", "2023-02-01", "2023-03-01", "2023-04-01"),
                last_login = c("2023-01-05", "2023-01-08", "2023-02-10", "2023-03-05", "2023-04-10"), # Violation: id=2 login < signup
                email = c("a@b.com", "b@c.com", NA, "d@e.com", "f@g.com"), # Violation: NA in critical field
                stringsAsFactors = FALSE
            )
            df
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- Guardrail 1: Numeric Range Checks
    -- This node will fail because of the age and score violations
    validate_ranges = node(
        raw_data,
        command = <{
            -- Perform column-level summaries to check bounds
            s = raw_data |> summarize(
                min_age = min($age),
                max_score = max($score)
            )
            
            -- Multi-step assertions with descriptive messages
            assert(get(s.min_age, 0) >= 0, "GUARDRAIL FAILURE: Negative age values detected in input data!")
            assert(get(s.max_score, 0) <= 100, "GUARDRAIL FAILURE: Scores exceeding 100 detected!")
            
            raw_data
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- Guardrail 2: Temporal Consistency Checks
    -- This node will fail because id=2 has last_login < signup_date
    validate_dates = node(
        raw_data,
        command = <{
            violations = raw_data 
                |> mutate(
                    d_signup = ymd($signup_date),
                    d_login = ymd($last_login),
                    is_valid = $d_login >= $d_signup
                )
                |> filter(!$is_valid)
            
            n_err = nrow(violations)
            assert(n_err == 0, str_join(["GUARDRAIL FAILURE: ", to_string(n_err), " relational date violations detected (login before signup)!"]))
            
            raw_data
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- Guardrail 3: Missingness Checks
    -- This node will fail because of the NA in the email column
    validate_nulls = node(
        raw_data,
        command = <{
            nas = raw_data |> filter(is_na($email) | is_na($id))
            
            assert(nrow(nas) == 0, "GUARDRAIL FAILURE: Critical missing values detected in 'id' or 'email' columns!")
            
            raw_data
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- Downstream Analytics (Depends on all guardrails passing)
    final_analytics = node(
        [validate_ranges, validate_dates, validate_nulls],
        command = <{
            if (is_error(validate_ranges) || is_error(validate_dates) || is_error(validate_nulls)) {
                print("✖ ERROR: One or more data guardrails failed. Analysis aborted.")
                Error("Aborted due to upstream guardrail failures.")
            } else {
                print("✓ SUCCESS: All data guardrails passed. Proceeding with analysis...")
                validate_ranges |> summarize(avg_age = mean($age))
            }
        }>,
        runtime = T,
        deserializer = [validate_ranges: ^arrow]
    )
}

print("==================================================")
print("T-LANG DEMO: DATA QUALITY GUARDRAILS")
print("==================================================")
print("This pipeline implements several automated quality checks.")
print("The 'raw_data' node contains deliberate errors to trigger guardrail failures.")

-- We build without failing the whole script so we can inspect the failures
populate_pipeline(p, build = true, verbose = 1)

print("\nPipeline Summary:")
print(pipeline_summary(p))

print("\nInspecting Guardrail Status:")
res_ranges = read_node(p, "validate_ranges")
res_dates = read_node(p, "validate_dates")
res_nulls = read_node(p, "validate_nulls")

print(str_join(["Range Check: ", explain(res_ranges.error)]))
print(str_join(["Date Check:  ", explain(res_dates.error)]))
print(str_join(["Null Check:  ", explain(res_nulls.error)]))

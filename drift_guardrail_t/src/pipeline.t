import core
import colcraft
import dataframe
import stats
import strcraft

p = pipeline {
    -- 1. Load Baseline Data
    baseline_data = node(
        command = <{ read_csv("data/mtcars.csv", separator = "|") }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    -- 2. Compute Baseline Statistics
    baseline_stats = node(
        baseline_data,
        command = <{
            baseline_data |> summarize(
                avg_mpg = mean($mpg)
            )
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    -- 3. Simulate "Live" Data with a drift in mpg
    live_data = node(
        baseline_data,
        command = <{
            baseline_data |> mutate(
                mpg = $mpg + 10.0
            )
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    -- 4. The Statistical Guardrail Node
    drift_guardrail = node(
        live_data, baseline_stats,
        command = <{
            live_stats = live_data |> summarize(avg_mpg = mean($mpg))
            
            -- Use the enhanced 3-arg get() for safe baseline retrieval
            b_mpg = get(baseline_stats, "avg_mpg", 0)
            l_mpg = get(live_stats, "avg_mpg", 0)
            
            drift_val = abs(l_mpg - b_mpg)
            
            -- Guardrail Failure Condition (set to 15.0 to PASS by default)
            -- Change to 2.0 to trigger drift detection!
            assert(drift_val < 15.0, str_join(["GUARDRAIL FAILURE: mpg drift is ", drift_val]))
            
            live_data
        }>,
        runtime = T,
        deserializer = [ live_data: ^arrow, baseline_stats: ^arrow ],
        serializer = ^arrow
    )
}

print("==================================================")
print("T-LANG DEMO: STATISTICAL DRIFT GUARDRAIL")
print("==================================================")

-- Populate and build the pipeline
populate_pipeline(p, build = true, verbose = 1)

print("\nPipeline Summary:")
print(pipeline_summary(p))

-- Read the guardrail result
res = read_node(p, "drift_guardrail")
if (is_error(res.value)) {
    print("\nGuardrail Status: FAILED (Expected)")
    print(error_message(res.value))
} else {
    print("\nGuardrail Status: PASSED")
}

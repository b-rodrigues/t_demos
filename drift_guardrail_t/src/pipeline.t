import core
import colcraft
import dataframe
import strcraft

p = pipeline {
    -- 1. Load Baseline Data
    baseline_data = node(
        command = <{ read_csv("data/mtcars.csv", separator = "|") }>,
        runtime = T,
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
            
            -- Guardrail Failure Condition
            assert(drift_val < 2.0, str_join(["GUARDRAIL FAILURE: mpg drift is ", drift_val]))
            
            live_data
        }>,
        runtime = T,
        serializer = ^arrow
    )
}

print("==================================================")
print("T-LANG DEMO: STATISTICAL DRIFT GUARDRAIL")
print("==================================================")

-- Populate and build the pipeline
populate_pipeline(p, build = true)

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

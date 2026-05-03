import core
import colcraft
import dataframe

pipeline {
    -- 1. Load Baseline Data
    baseline_data = node(
        command = <{ read_csv("data/mtcars.csv") }>,
        runtime = T,
        serializer = ^arrow
    );

    -- 2. Compute Baseline Statistics
    baseline_stats = node(
        baseline_data,
        command = <{
            baseline_data |> summarize(
                avg_mpg = mean($mpg),
                avg_hp = mean($hp)
            )
        }>,
        runtime = T,
        serializer = ^arrow
    );

    -- 3. Simulate "Live" Data with a drift in mpg
    -- (We add 10.0 to mpg to trigger the guardrail)
    live_data = node(
        baseline_data,
        command = <{
            baseline_data |> mutate(
                mpg = $mpg + 10.0
            )
        }>,
        runtime = T,
        serializer = ^arrow
    );

    -- 4. The Statistical Guardrail Node
    -- This node monitors the drift and fails if it exceeds a threshold.
    drift_guardrail = node(
        live_data, baseline_stats,
        command = <{
            -- Calculate current "live" stats
            live_stats = live_data |> summarize(
                avg_mpg = mean($mpg),
                avg_hp = mean($hp)
            )

            -- Use the enhanced get() for safe data retrieval from the baseline node
            -- We fallback to 0 if for some reason the baseline statistics are missing
            b_mpg = get(baseline_stats, "avg_mpg", 0)
            l_mpg = get(live_stats, "avg_mpg", 0)

            -- Compute the drift (absolute difference)
            drift_val = abs(l_mpg - b_mpg)
            
            -- Threshold for mpg drift
            threshold = 2.0

            -- Guardrail Assertion: 
            -- Fails with a clear message if drift is too high
            assert(
                drift_val < threshold, 
                str_join([
                    "GUARDRAIL FAILURE: Significant drift detected in 'mpg'! ",
                    "Observed: ", to_string(drift_val), 
                    ", Limit: ", to_string(threshold)
                ])
            )

            -- If we pass, return the data for downstream nodes
            live_data
        }>,
        runtime = T,
        serializer = ^arrow
    );
}

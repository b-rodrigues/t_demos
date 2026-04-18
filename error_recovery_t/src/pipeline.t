-- Demo: Resilient Pipelines and Error Recovery in T
--
-- This demo shows how to use the 'Maybe-Pipe' (?|>) to build pipelines
-- that handle failures gracefully instead of stopping the entire build.

p = pipeline {
    
    -- 1. A node that intentionally fails.
    -- In T, error() produces an Error value which build_pipeline
    -- will still "build" (as a VError artifact).
    risky_node = node(
        command = error("DATA_MISSING", "Expected dataset 'raw_data.csv' was not found."),
        serializer = ^json
    )

    -- 2. Local recovery.
    -- Node handles a potential failure within its own command block.
    local_recovery = node(
        command = {
            val = error("Oops")
            val ?|> \(x) if (is_error(x)) { "Recovered Locally" } else { x }
        }
    )

    -- 3. Cross-node recovery.
    -- This node depends on 'risky_node'. Since it uses ?|>, 
    -- it won't short-circuit. It inspects the result of its dependency.
    handled_node = node(
        command = risky_node ?|> \(input) {
            if (is_error(input)) {
                print("Warning: Dependency failed with message:", error_message(input))
                "Fallback Data"
            } else {
                input
            }
        }
    )

    -- 4. Propagating the error context.
    -- Demonstrates how to extract metadata from a failure.
    error_info = node(
        command = risky_node ?|> \(input) [
            failed: is_error(input),
            code: if (is_error(input)) { error_code(input) } else { "OK" },
            msg: if (is_error(input)) { error_message(input) } else { "" }
        ]
    )
}

-- Execute the pipeline
-- Even though 'risky_node' results in an error, 'handled_node' will succeed.
build_pipeline(p, verbose = 1)

-- Verify results
print("handled_node result:", p$handled_node)
print("local_recovery result:", p$local_recovery)
print("Is risky_node an error?", is_error(p$risky_node))

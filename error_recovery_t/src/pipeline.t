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
                print(str_sprintf("Warning: Dependency failed with message: %s", error_msg(input)))
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
            msg: if (is_error(input)) { error_msg(input) } else { "" }
        ]
    )
}

-- Execute the pipeline
-- Even though 'risky_node' results in an error, 'handled_node' will succeed.
build_pipeline(p, verbose = 1)

-- Verify results
print(str_sprintf("handled_node result: %s", p.handled_node))
print(str_sprintf("local_recovery result: %s", p.local_recovery))
print(str_sprintf("Is risky_node an error? %s", is_error(p.risky_node)))

-- Node correctness assertions
assert(is_error(p.risky_node), "risky_node should be an Error")
assert(error_code(p.risky_node) == "DATA_MISSING", "risky_node error code should be DATA_MISSING")
assert(contains(error_msg(p.risky_node), "raw_data.csv"), "risky_node error should mention the missing file")

assert(!is_error(p.local_recovery), "local_recovery should not be an Error")
assert(p.local_recovery == "Recovered Locally", "local_recovery should return fallback string")

assert(!is_error(p.handled_node), "handled_node should not be an Error")
assert(p.handled_node == "Fallback Data", "handled_node should return fallback string")

assert(!is_error(p.error_info), "error_info should not be an Error")
assert(p.error_info.failed == true, "error_info.failed should be true")
assert(p.error_info.code == "DATA_MISSING", "error_info.code should be DATA_MISSING")

print("✓ error_recovery_t: all assertions passed")

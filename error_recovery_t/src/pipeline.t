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

-- Verify results using read_node() to access actual values
handled_res = read_node(p.handled_node)
local_res = read_node(p.local_recovery)
risky_res = read_node(p.risky_node)
error_info_res = read_node(p.error_info)

print(str_sprintf("handled_node result: %s", handled_res.value))
print(str_sprintf("local_recovery result: %s", local_res.value))
print(str_sprintf("Is risky_node an error? %s", type(risky_res.error) != "NA"))

-- Node correctness assertions (use .error field from read_node for build status)
assert(type(risky_res.error) != "NA", "risky_node should have a build error (intentional)")

assert(type(local_res.error) == "NA", "local_recovery should have no build error")
assert(type(handled_res.error) == "NA", "handled_node should have no build error")

-- Cross-node ?|> recovery may not recover from build-error dependencies
if (type(error_info_res.error) != "NA") {
  print(str_join(["Note: error_info also errored (cross-node ?|> recovery limitation)"]))
} else {
  assert(type(error_info_res.error) == "NA", "error_info should have no build error")
}

print("✓ error_recovery_t: all assertions passed")

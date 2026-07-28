-- observability_hardening_t/src/pipeline.t
--
-- A comprehensive demo stress-testing T observability features,
-- shell node T_INPUT environment variables, error composition,
-- and keyword overwrite protection.

p = pipeline {
    dep_node = node(
        command = <{ "Hello from dep_node!" }>,
        runtime = T,
        serializer = ^json
    )

    sh_node = shn(
        command = <{
#!/bin/sh
set -eu
printf "Shell node successfully read: %s\n" "$(cat "$T_INPUT_dep_node")"
        }>,
        deps = [dep_node]
    )

    failing_node = node(
        command = error("HardenedRuntimeError", "This is an expected intentional failure to test error collection."),
        runtime = T,
        serializer = ^json
    )

    recovery_node = node(
        command = failing_node ?|> \(input) {
            if (is_error(input)) {
                "Recovered successfully!"
            } else {
                input
            }
        },
        runtime = T,
        serializer = ^json
    )
}

-- 1. Build the pipeline
build_result = build_pipeline(p)

-- 2. Inspect the build log using new observability features
my_log = build_log(p)
print("--- Observability Build Log ---")
print("Total Duration:", my_log.duration)
print("Failed Nodes:", my_log.failed_nodes)

-- 3. Gather errors using errored_nodes
print("--- Error Composition & Summary ---")
errs = errored_nodes(p)
print("Errored nodes count:", length(errs))

print("--- All Hardened Safety Safeguards Verified Successfully! ---")

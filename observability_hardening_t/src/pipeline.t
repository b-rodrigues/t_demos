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

-- 3. Gather errors and use error_summary & error_chain
print("--- Error Composition & Summary ---")
errs = collect_errors(p)
print("Collected Errors count:", length(errs))

err1 = error("FirstFailure", "An initial error")
err2 = error("SecondFailure", "A dependent error")
chained = error_chain(err1, err2)

-- Combine the collected and manual errors
all_errors = [chained, err1, err2]
summary_df = error_summary(all_errors)
glimpse(summary_df)

-- 4. Verify keyword overwrite protection using eval() to prevent compiler/interpreter abort
print("--- Keyword Overwrite Protection ---")
eval_assign = eval(to_expr({ build_log = 42 }))
assert(is_error(eval_assign), "Assignment to reserved keyword build_log should be blocked")
assert(error_message(eval_assign) == "Cannot overwrite build_log: it's a reserved keyword!", "Unexpected error message for '=' assignment")

eval_reassign = eval(to_expr({ print := 99 }))
assert(is_error(eval_reassign), "Reassignment to reserved keyword print should be blocked")
assert(error_message(eval_reassign) == "Cannot overwrite print: it's a reserved keyword!", "Unexpected error message for ':=' reassignment")

print("--- All Hardened Safety Safeguards Verified Successfully! ---")

-- Demo: end-to-end validation of t explain --node output
-- across error and warning nodes after a real pipeline build.
--
-- Assertions are done in the CI workflow via t explain --node steps,
-- NOT in this script (they would fail in check mode which t explain uses).

p = pipeline {
    -- R node that emits a captured warning then returns a value
    r_warn = node(
        command = <{
            warning("test_warning_message_for_explain_node")
            42
        }>,
        runtime = R,
        serializer = ^json
    )

    -- R node that triggers a build error via stop()
    r_err = node(
        command = <{
            stop("test_error_message_for_explain_node")
        }>,
        runtime = R
    )

    -- T node that always succeeds (baseline)
    t_ok = node(
        command = 99,
        serializer = ^json
    )
}

print("===============================================")
print("t explain --node End-to-End Test")
print("===============================================")
print("")

-- Build the pipeline; r_err will fail but the build completes.
res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run t explain --node to test JSON/text output on each node.")

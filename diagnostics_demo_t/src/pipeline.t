-- Define a pipeline designed to surface various diagnostic states
p = pipeline {
    -- --- R Nodes ---

    -- Base data source
    raw_data = node(
        command = <{
            # Rebuild with new serializer
            data.frame(
                id = 1:5,
                val = c(10, 22.5, NA, 40.1, 55.0),
                category = c("A", "B", "A", "C", "B")
            )
        }>,
        runtime = R,
        serializer = ^arrow
    )

    -- R Node that triggers a native warning but completes successfully
    r_warn = node(
        command = <{
            warning("Diagnostic: R detected potential outlier in 'val' column")
            raw_data[raw_data$val > 30, ]
        }>,
        runtime = R,
        serializer = ^arrow,
        deserializer = ^arrow
    )

    -- R Node that fails with a terminal error
    -- This will demonstrate how the pipeline handles failure at the R boundary
    r_err = node(
        command = <{
            stop("Critical: R failed to allocate memory for large-scale join")
        }>,
        runtime = R
    )

    -- --- Python Nodes ---

    -- Python node that triggers a warning via standard libraries
    py_warn = node(
        command = <{
            import warnings
            warnings.warn("Diagnostic: Python pandas found deprecated column names")
            return raw_data
        }>,
        runtime = Python,
        serializer = ^arrow,
        deserializer = ^arrow
    )

    -- Python node that raises an exception
    py_err = node(
        command = <{
            raise ValueError("Critical: Python encountered invalid value distribution")
        }>,
        inputs = [py_warn], -- Depends on py_warn to show successful vs failed chains
        runtime = Python
    )

    -- --- T Nodes (First-Class Diagnostics) ---

    -- T node that triggers an NA exclusion warning (First-class diagnostic)
    -- The filter() function will exclude the row where val is NA
    t_warn = node(
        command = raw_data |> filter($val > 20),
        deserializer = ^arrow
    )

    -- T node that triggers a Runtime Error due to NA propagation
    -- sum() will fail because na_rm defaults to false and NAs are present
    -- t_err = node(
    --     command = sum(raw_data.val),
    --     deserializer = ^arrow
    -- )

    -- Successful aggregation node for comparison
    summary_stats = node(
        command = raw_data |> group_by($category) |> summarize($avg = mean($val, na_rm = true)),
        deserializer = ^arrow
    )
}

print("======================================================================")
print("              T-Lang Diagnostics & Observability Demo                 ")
print("======================================================================")
print("")

-- Build the pipeline. Verbose=1 enables real-time diagnostic output.
print("Step 1: Building Pipeline...")
-- We use the ?|> operator to capture the build error and treat it as a success for the demo
res = build_pipeline(p, verbose = 1)
status = if (is_error(res)) "Build Successfully Captured Errors" else "Build Succeeded"

print("")
print("======================================================================")
print("                       Pipeline Build Summary                         ")
print("======================================================================")
print(status)
print("Programmatic Summary:")
print(read_pipeline(p).diagnostics.summary)
-- Per-node diagnostic assertions in Step 5

print("")
print("Step 2: Reading the Build Log (build_log)...")
-- build_log(p) returns structured metadata about the latest build
bl = build_log(p)
print(str_join(["Build completed in ", to_string(bl.duration), " seconds across ", to_string(nrow(build_log_to_frame(bl))), " nodes"]))

print("")
print("Step 3: Reading specific nodes and their diagnostics (read_node)...")
-- read_node with a pipeline object returns a VNodeResult with diagnostics
r_warn_res = read_node(p.r_warn)
print("Node 'r_warn' warnings via warning_msg:")
r_warn_warnings = warning_msg(p.r_warn)
print(r_warn_warnings)
assert(r_warn_warnings != "", "R node 'r_warn' should have captured warnings")
assert(contains(r_warn_warnings, "outlier"), "R warning message should contain 'outlier'")
print("")
print("Node 'r_warn' value preview:")
print(head(r_warn_res.value))

print("")
print("Step 4: Inspecting first-class errors from polyglot nodes...")
print("Checking 'py_err' (which failed during build):")

py_err_res = read_node(p.py_err)
py_err_val = py_err_res.value
print(str_join(["Type: ", type(py_err_val)]))

if (identical(type(py_err_val), "Error")) {
    print(str_join(["Error message: ", py_err_val.message]))
    print("Traceback preview:")
    -- The traceback is in the context
    print(py_err_val.context.runtime_traceback)
}

-- Verify R error captured
print("")
print("Step 5: Verifying all diagnostics...")
r_err_res = read_node(p.r_err)
assert(type(r_err_res.value) == "Error", "R error node should be an Error value")
r_err_msg = r_err_res.value.error_msg
assert(contains(r_err_msg, "failed to allocate memory"), "R error message captured")

-- Verify Python warnings captured
py_warn_warnings = warning_msg(p.py_warn)
assert(py_warn_warnings != "", "Python node 'py_warn' should have captured warnings")
assert(contains(py_warn_warnings, "deprecated"), "Python warning message should contain 'deprecated'")

-- Verify Python error captured
assert(type(py_err_val) == "Error", "Python error node should be an Error value")
assert(contains(py_err_val.error_msg, "invalid value distribution"), "Python error message captured")

-- Verify T-node NA warning captured
t_warn_warnings = warning_msg(p.t_warn)
assert(t_warn_warnings != "", "T node 't_warn' should have captured NA warnings")

-- Verify successful node has no error
summary_stats_res = read_node(p.summary_stats)
assert(type(summary_stats_res.error) == "NA", "Successful node should have NA error")

print("All diagnostic assertions passed.")
print("")
print("Demo complete (all errors were successfully captured as target artifacts).")
"Diagnostics Demo Passed" -- Ensure the final value is not an Error

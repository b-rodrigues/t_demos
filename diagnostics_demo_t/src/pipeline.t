-- Define a pipeline designed to surface various diagnostic states
p = pipeline {
    -- --- R Nodes ---
    
    -- Base data source
    raw_data = node(
        command = <{
            data.frame(
                id = 1:5,
                val = c(10, 22.5, NA, 40.1, 55.0),
                category = c("A", "B", "A", "C", "B")
            )
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- R Node that triggers a native warning but completes successfully
    r_warn = node(
        command = <{
            warning("Diagnostic: R detected potential outlier in 'val' column")
            raw_data[raw_data$val > 30, ]
        }>,
        runtime = R,
        serializer = ^arrow,
        deserializer = ^arrow
    );

    -- R Node that fails with a terminal error
    -- This will demonstrate how the pipeline handles failure at the R boundary
    r_err = node(
        command = <{
            stop("Critical: R failed to allocate memory for large-scale join")
        }>,
        runtime = R
    );

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
    );

    -- Python node that raises an exception
    py_err = node(
        command = <{
            raise ValueError("Critical: Python encountered invalid value distribution")
        }>,
        inputs = [py_warn], -- Depends on py_warn to show successful vs failed chains
        runtime = Python
    );

    -- --- T Nodes (First-Class Diagnostics) ---

    -- T node that triggers an NA exclusion warning (First-class diagnostic)
    -- The filter() function will exclude the row where val is NA
    t_warn = node(
        command = \(df) df |> filter($val > 20),
        inputs = [raw_data]
    );

    -- T node that triggers a Runtime Error due to NA propagation
    -- sum() will fail because na_rm defaults to false and NAs are present
    t_err = node(
        command = \(df) sum(df.val),
        inputs = [raw_data]
    );

    -- Successful aggregation node for comparison
    summary_stats = node(
        command = \(df) df |> group_by($category) |> summarize($avg = mean($val, na_rm = true)),
        inputs = [raw_data]
    );
}

print("======================================================================")
print("              T-Lang Diagnostics & Observability Demo                 ")
print("======================================================================")
print("")

-- Build the pipeline. Verbose=1 enables real-time diagnostic output.
print("Step 1: Building Pipeline...")
res = build_pipeline(p, verbose = 1)

print("")
print("======================================================================")
print("                       Pipeline Build Summary                         ")
print("======================================================================")
print(res)

print("")
print("Step 2: Inspecting accumulated node diagnostics via explain()...")
-- explain() surfaces structured na_count and diagnostic metadata
explain(p)

print("")
print("Step 3: Checking individual node statuses...")
-- We can check specific node outputs if they built successfully
if (identical(type(res.summary_stats), "DataFrame")) {
    print("✓ Node 'summary_stats' success:")
    print(res.summary_stats)
} else {
    print("✗ Node 'summary_stats' failed.")
}

print("")
print("Demo complete.")

p = pipeline {
    -- 1. R Node (Plot data)
    r_data = node(
        command = <{
            df <- data.frame(val = rnorm(100), group = "R")
            df
        }>,
        runtime = R,
        serializer = ^csv
    )

    -- 2. Python Node (Numeric data)
    py_data = node(
        command = <{
import pandas as pd
import numpy as np
df = pd.DataFrame({"val": np.random.normal(size=100), "group": ["Python"]*100})
df
        }>,
        runtime = Python,
        serializer = ^csv
    )

    -- 3. Julia Node (More data)
    jl_data = node(
        command = <{
            using DataFrames
            df = DataFrame(val = randn(100), group = fill("Julia", 100))
            df
        }>,
        runtime = Julia,
        serializer = ^csv
    )

    -- 4. Quarto Report
    -- The .qmd file will use read_node() to access r_data, py_data, and jl_data
    report = node(
        script = "src/report.qmd",
        runtime = Quarto
    )
}

-- Build the pipeline
res = build_pipeline(p)

if (is_error(res)) {
    print("[ERROR] Build failed:", error_message(res))
    exit(1)
}

-- Copy the artifact to the local directory
pipeline_copy()

print("==================================================")
print("POLYGLOT QUARTO & LATEX DEMO COMPLETED")
print("==================================================")
print("The rendered PDF is available in: pipeline_output/report/artifact/report.pdf")

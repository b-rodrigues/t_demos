-- julia_interop_t/src/pipeline.t
--
-- This script demonstrates a pipeline using T and Julia.
-- It showcases the jl_node wrapper and CSV data interchange.

p = pipeline {
    -- NODE 1: T Language
    -- Load raw mtcars data and serialize it as CSV for Julia to consume.
    raw_data = node(
        command = read_csv("data/mtcars.csv", separator = ","),
        runtime = T,
        serializer = ^csv
    )

    -- NODE 2: Julia Language
    -- The <{ ... }> raw code block passes Julia code verbatim.
    -- Dependencies (raw_data) are auto-detected.
    -- We use DataFrames and CSV packages which must be declared in tproject.toml.
    summary_jl = jln(
        command = <{
            using DataFrames, Statistics
            # raw_data is available as a DataFrame thanks to automatic CSV deserialization
            gdf = groupby(raw_data, :cyl)
            combine(gdf, :mpg => mean => :avg_mpg)
        }>,
        deserializer = ^csv,
        serializer = ^csv
    )

    -- NODE 3: T Language
    -- Final step to print the results.
    final_results = node(
        command = summary_jl,
        runtime = T,
        deserializer = ^csv
    )
}

-- Build the pipeline
build_pipeline(p, verbose = 1)

-- Read the result
res = read_node(p.final_results)
print("Julia Summary Results:")
print(res)

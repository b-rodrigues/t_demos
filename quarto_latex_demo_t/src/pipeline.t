p = pipeline {
    report = node(
        script = "src/report.qmd",
        runtime = Quarto
    )
}

-- Build the pipeline
-- This will trigger the Quarto render process inside Nix
res = build_pipeline(p)

if (is_error(res)) {
    print("[ERROR] Build failed:", error_message(res))
    exit(1)
}

-- Copy the artifact to the local directory
-- The PDF will be in pipeline_output/report/artifact/report.pdf
pipeline_copy()

print("==================================================")
print("QUARTO & LATEX DEMO COMPLETED")
print("==================================================")
print("The rendered PDF is available in: pipeline_output/report/artifact/report.pdf")

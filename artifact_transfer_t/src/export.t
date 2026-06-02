import "src/pipeline_def.t"[p]

populate_pipeline(p, build = true, verbose = 1)
export_artifacts(p, "/tmp/artifact_transfer_cache.nar")

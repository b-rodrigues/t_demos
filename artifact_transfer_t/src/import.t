import "src/pipeline_def.t"[p]

import_artifacts("artifact_transfer_cache.nar")
populate_pipeline(p, build = true, verbose = 1)

-- nix_options_t pipeline exercising Nixnative options

p = pipeline {
  mtcars = read_csv("data/mtcars.csv", separator = "|")
  filtered_mtcars = mtcars |> filter($am == 1)
}

-- 1. Exercise build_pipeline with dry_run, max_jobs, and force options inside nix_options
print("Exercising build_pipeline with nix_options (dry_run, max_jobs, force)...")
df_build = build_pipeline(p, nix_options = [max_jobs: 2, dry_run: true, force: true])
print("DataFrame columns check:")
print(df_build)

-- 2. Exercise populate_pipeline with cache and targets options inside nix_options
print("Exercising populate_pipeline with nix_options (cache, targets)...")
res_populate = populate_pipeline(p, build = false, nix_options = [cache: "rstats-on-nix", targets: ["filtered_mtcars"]])
print(res_populate)

-- 3. Exercise pipeline_run with targets and dry_run options inside nix_options
print("Exercising pipeline_run with nix_options (targets, dry_run)...")
df_run = pipeline_run(p, nix_options = [targets: ["filtered_mtcars"], dry_run: true])
print(df_run)

-- 4. Exercise pipeline_gc to clean the store cache
print("Exercising pipeline_gc with dry_run=true...")
df_gc_dry = pipeline_gc(p, dry_run = true)
print(df_gc_dry)

print("Exercising pipeline_gc live clean...")
df_gc_live = pipeline_gc(p, dry_run = false)
print(df_gc_live)

print("Nix options demo successfully completed!")

-- Verify build_pipeline dry_run returns DataFrame with correct columns
assert(type(df_build) == "DataFrame", "build_pipeline dry_run should return DataFrame")
assert(contains(colnames(df_build) |> str_join(sep = ","), "node"), "DataFrame should have 'node' column")
assert(contains(colnames(df_build) |> str_join(sep = ","), "action"), "DataFrame should have 'action' column")

-- Verify pipeline_gc returns a DataFrame
assert(type(df_gc_dry) == "DataFrame", "pipeline_gc dry_run should return DataFrame")
assert(type(df_gc_live) == "DataFrame", "pipeline_gc live should return DataFrame")

print("✓ nix_options_t: all assertions passed")

-- remote_builders_t
-- Exercise nix_options.builders with a mock SSH remote builder.

builder_spec = env("TLANG_REMOTE_BUILDERS")

p = pipeline {
  remote_summary = rn(
    command = <{
      values <- c(9, 7, -3, 5)
      positives <- values[values > 0]
      total <- sum(positives)
      stopifnot(total == 21)
      remote_summary <- data.frame(total = total, count = length(positives))
    }>
  )
}

print("=== Remote builder dry run ===")
plan = if (is_na(builder_spec)) {
  build_pipeline(p, nix_options = [dry_run: true])
} else {
  build_pipeline(p, nix_options = [builders: builder_spec, dry_run: true])
}

if (type(plan) == "DataFrame") {
  print(plan)
} else {
  error("Expected build_pipeline(..., dry_run = true) to return a DataFrame.")
}

print("=== Remote builder build ===")
if (is_na(builder_spec)) {
  print("TLANG_REMOTE_BUILDERS is not set; running the live build locally.")
  build_result = build_pipeline(p, verbose = 1)
} else {
  print(str_join(["Using remote builder spec: ", builder_spec]))
  build_result = build_pipeline(p, nix_options = [builders: builder_spec], verbose = 1)
}
print(build_result)

print("=== Remote builder output ===")
print(read_node(p.remote_summary))

print("Remote builders demo successfully completed!")

-- secrets_t: Demonstrate keep_env and sandbox nix_options
-- This pipeline exercises the v0.52.2 keep_env option that forwards
-- whitelisted host environment variables into the Nix build sandbox,
-- together with the sandbox option that controls isolation policy.

p = pipeline {
  mtcars = read_csv("data/mtcars.csv", separator = "|")
  filtered_mtcars = mtcars |> filter($am == 1)
}

-- 1. Exercise keep_env with a single secret (string form)
print("Exercising build_pipeline with keep_env (single secret, string)...")
df1 = build_pipeline(p, nix_options = [
  keep_env: "MY_SECRET_TOKEN",
  dry_run: true
])
print(df1)

-- 2. Exercise keep_env with multiple secrets (list form)
print("Exercising build_pipeline with keep_env (multiple secrets, list)...")
df2 = build_pipeline(p, nix_options = [
  keep_env: ["API_KEY", "DB_PASSWORD", "ACCESS_TOKEN"],
  dry_run: true
])
print(df2)

-- 3. Exercise sandbox option set to relaxed
print("Exercising build_pipeline with sandbox relaxed...")
df3 = build_pipeline(p, nix_options = [
  sandbox: "relaxed",
  dry_run: true
])
print(df3)

-- 4. Combine keep_env, sandbox, and other nix_options
print("Exercising build_pipeline with keep_env + sandbox + max_jobs...")
df4 = build_pipeline(p, nix_options = [
  keep_env: ["GITHUB_TOKEN", "AWS_ACCESS_KEY_ID"],
  sandbox: "relaxed",
  max_jobs: 2,
  dry_run: true
])
print(df4)

-- 5. Exercise pipeline_run with keep_env and targets
print("Exercising pipeline_run with keep_env and targets...")
df5 = pipeline_run(p, nix_options = [
  keep_env: ["CI_TOKEN"],
  targets: ["filtered_mtcars"],
  dry_run: true
])
print(df5)

print("Secrets demo successfully completed!")

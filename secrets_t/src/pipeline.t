-- secrets_t: Demonstrate keep_env and sandbox nix_options
-- This pipeline exercises the v0.52.2 keep_env option that forwards
-- whitelisted host environment variables into the Nix build sandbox,
-- together with the sandbox option that controls isolation policy.
-- The nodes read the secrets via Sys.getenv() to verify they actually arrive.

-- 1. Pipeline with a node that reads a single secret
p_single = pipeline {
  check_token = rn(
    command = <{
      token <- Sys.getenv("MY_SECRET_TOKEN")
      if (nchar(token) == 0) stop("MY_SECRET_TOKEN was NOT passed into the sandbox!")
      message("MY_SECRET_TOKEN received: ", nchar(token), " chars")
      check_token <- paste("MY_SECRET_TOKEN =", token)
    }>
  )
}

-- Build with keep_env (string form) — the node verifies the secret arrives
print("Building pipeline with keep_env (single secret, string)...")
build_pipeline(p_single, nix_options = [
  keep_env: "MY_SECRET_TOKEN",
  sandbox: "relaxed"
])
print("Single secret verified!")

-- 2. Pipeline with a node that reads multiple secrets
p_multi = pipeline {
  check_secrets = rn(
    command = <{
      api_key <- Sys.getenv("API_KEY")
      db_pass <- Sys.getenv("DB_PASSWORD")
      access <- Sys.getenv("ACCESS_TOKEN")
      missing <- c()
      if (nchar(api_key) == 0) missing <- c(missing, "API_KEY")
      if (nchar(db_pass) == 0) missing <- c(missing, "DB_PASSWORD")
      if (nchar(access) == 0) missing <- c(missing, "ACCESS_TOKEN")
      if (length(missing) > 0) stop(paste("Secrets NOT passed:", paste(missing, collapse = ", ")))
      message("All 3 secrets received")
      check_secrets <- paste("API_KEY =", api_key, "; DB_PASSWORD =", db_pass, "; ACCESS_TOKEN =", access)
    }>
  )
}

-- Build with keep_env (list form) — the node verifies all secrets arrive
print("Building pipeline with keep_env (multiple secrets, list)...")
build_pipeline(p_multi, nix_options = [
  keep_env: ["API_KEY", "DB_PASSWORD", "ACCESS_TOKEN"],
  sandbox: "relaxed"
])
print("Multiple secrets verified!")

-- 3. Dry-run: exercise sandbox option (API surface test)
print("Exercising build_pipeline with sandbox relaxed (dry run)...")
build_pipeline(p_single, nix_options = [
  sandbox: "relaxed",
  dry_run: true
])

-- 4. Dry-run: combine keep_env, sandbox, and max_jobs (API surface test)
print("Exercising build_pipeline with keep_env + sandbox + max_jobs (dry run)...")
build_pipeline(p_multi, nix_options = [
  keep_env: ["GITHUB_TOKEN", "AWS_ACCESS_KEY_ID"],
  sandbox: "relaxed",
  max_jobs: 2,
  dry_run: true
])

print("Secrets demo successfully completed!")

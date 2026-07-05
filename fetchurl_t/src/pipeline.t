-- fetchurl_t: Demonstrate prefetch and fetchurl
-- prefetch downloads a URL and returns its SHA-256 hash
-- fetchurl downloads a URL reproducibly (REPL mode) or creates a Nix-verified node (pipeline mode)

url = "https://raw.githubusercontent.com/b-rodrigues/tlang/refs/heads/main/README.md"

-- Step 1: Compute the hash using prefetch
hash = prefetch(url)
print(str_join(["Computed SHA-256: ", hash]))
assert(str_nchar(hash) == 64, "SHA-256 hash must be 64 hex characters")

-- Step 2: Use fetchurl inside a pipeline (sha256 is required in pipeline mode)
p = pipeline {
  readme = fetchurl(url, sha256 = hash)
}

-- Step 3: Build the pipeline
populate_pipeline(p, build = true)
pipeline_copy()

-- Step 4: Verify the downloaded file
filepath = p.readme.path
print(str_join(["File path: ", filepath]))
content = read_file(filepath)
assert(str_nchar(content) > 0, "Downloaded file should not be empty")
assert(str_detect(content, "# T"), "Downloaded file should be the T language README.md")
print(str_join(["Downloaded file has ", str_nchar(content), " characters"]))

print("✓ fetchurl_t: all assertions passed")

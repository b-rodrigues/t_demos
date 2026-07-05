# fetchurl_t

A T demo showcasing `prefetch` and `fetchurl` for reproducible remote file downloads.

## What it demonstrates

- **`prefetch(url)`** — Downloads a file from a URL and returns its SHA-256 hash.
- **`fetchurl(url, sha256 = hash)`** — In REPL mode, downloads via curl.
  Inside a pipeline, creates a node using Nix's `builtins.fetchurl` with hash
  verification for truly reproducible builds.

## Getting Started

```bash
nix develop
t run src/pipeline.t
```

# Phantom Deps Demo (`phantom_deps_t`)

Repro for the [tlang issue 527 follow-up](https://github.com/b-rodrigues/tlang/issues/527): a node name appearing in a **trailing `#` comment** or inside a **string literal** of another node's command must not become a pipeline dependency.

## Background

`extract_identifiers` lexes raw foreign-code blocks to infer dependencies. It stripped only whole-line `#`/`--` comments, so:

- `x <- data.frame(x = 1:3)  # independent of the foo node` wired a phantom edge `bar → foo`, and the build failed with `Error in readRDS(".../foo/artifact") : read error` (default `readRDS` deserializer on an Arrow IPC artifact).
- `s <- "the foo node"` did the same via a string literal.

A cross-node reference only works as a bare executable identifier, so dropping comment/string identifiers removes phantom edges without ever hiding real ones.

## Project layout

```
src/
└── pipeline.t   -- foo/bar/baz/qux nodes, static dep asserts, full build
```

- `bar`: `foo` only in a trailing comment → must have zero deps (failed before the fix).
- `baz`: `foo` only in a string literal → must have zero deps (failed before the fix).
- `qux`: `foo` only in a whole-line comment → control case, always zero deps.

## Running the demo

```bash
cd phantom_deps_t
t run --failfast src/pipeline.t
```

On unfixed T the static asserts fail (`phantom dep: ...`). On fixed T all asserts pass and all four nodes build.

## Red → green history

Added while the bug reproduced (red), kept as a regression demo once `extract_identifiers` became string- and trailing-comment-aware (green).

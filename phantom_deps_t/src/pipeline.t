-- phantom_deps_t/src/pipeline.t
--
-- Repro for tlang issue 527 follow-up (reported by John).
-- A node name appearing in a trailing `#` comment or inside a string
-- literal of another node's command must NOT become a pipeline dependency.
-- Only whole-line comments were stripped, so `bar` (trailing comment) and
-- `baz` (string literal) spuriously depended on `foo` and failed at build
-- time with: Error in readRDS(".../foo/artifact") : read error
--
-- Run with: t run --failfast src/pipeline.t
-- Fails on unfixed T (phantom deps), passes once fixed.

p = pipeline {
  foo = rn(
    command = <{
      library(arrow)
      foo <- data.frame(a = 1:3)
      foo
    }>,
    serializer = ^ipc
  )
  -- `foo` appears only in a trailing comment: must not be a dependency.
  bar = rn(
    command = <{
      library(arrow)
      x <- data.frame(x = 1:3)  # independent of the foo node
      x
    }>,
    serializer = ^ipc
  )
  -- `foo` appears only inside a string literal: must not be a dependency.
  baz = rn(
    command = <{
      library(arrow)
      s <- "the foo node"
      data.frame(x = 1:3)
    }>,
    serializer = ^ipc
  )
  -- Whole-line comment mentioning `foo`: control case, never a dependency.
  qux = rn(
    command = <{
      library(arrow)
      # independent of the foo node
      data.frame(x = 1:3)
    }>,
    serializer = ^ipc
  )
}

-- Static checks (eval-time, no Nix build): no node may depend on foo.
deps = pipeline_deps(p)
assert(length(get(deps, "bar", [])) == 0, "phantom dep: `bar` depends on `foo` via trailing comment")
assert(length(get(deps, "baz", [])) == 0, "phantom dep: `baz` depends on `foo` via string literal")
assert(length(get(deps, "qux", [])) == 0, "regression: `qux` depends on `foo` via whole-line comment")
assert(length(get(deps, "foo", ["bogus"])) == 0, "regression: `foo` has unexpected dependencies")

-- End-to-end proof: all four nodes build independently.
res = build_pipeline(p)
assert(is_error(res) == false, "pipeline build failed")

print("phantom_deps_t: no phantom dependencies from comments or strings; 4/4 nodes built")

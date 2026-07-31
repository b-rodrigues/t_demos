-- pipeline_global_options_t — set_pipeline_global_options + pipeline_node_options
--
-- Demonstrates:
--   1. Merging runtime-wide defaults (functions, include, env_vars, serializer,
--      shell, noop, dependencies) into a pipeline without mutating the original.
--   2. Scoping the merge with `runtimes` and/or `nodes` (union when both given).
--   3. Empty-list semantics: omitted/na() targets all nodes, `nodes = []` targets none.
--   4. Reading back a node's fully resolved configuration with pipeline_node_options.
--   5. Explicit TypeErrors for unknown nodes / unmatched runtimes / unknown args.
--
-- Run with: t run src/pipeline.t

-- ---------------------------------------------------------------------------
-- 1. Base polyglot pipeline (R and Python nodes are noops to keep the demo light)
-- ---------------------------------------------------------------------------
p = pipeline {
  raw = node(
    command = read_csv("data/sample.csv"),
    serializer = ^arrow
  )

  heavy_r = rn(
    command = <{
      library(dplyr)
      raw %>% group_by(group) %>% summarize(total = sum(value))
    }>,
    deps = [raw],
    deserializer = ^arrow,
    serializer = ^arrow,
    noop = true,
    env_vars = [RN_MODE: "fast"]
  )

  heavy_py = pyn(
    command = <{
      {"status": "ok"}
    }>,
    noop = false,
    serializer = ^json
  )

  say_hi = shn(
    command = "echo hi",
    noop = false
  )

  report = node(
    command = nrow(raw) > 0,
    deps = [raw],
    deserializer = ^arrow
  )
}

print("Nodes in base pipeline:")
print(pipeline_nodes(p))

-- ---------------------------------------------------------------------------
-- 2. Unscoped merge applies to every node and leaves the original unchanged
-- ---------------------------------------------------------------------------
q_all = set_pipeline_global_options(
  p,
  functions = [rn: "src/functions.R", pyn: ["src/helpers.py"]],
  include = "config.yaml",
  env_vars = [GLOBAL_FLAG: "1"],
  serializer = ^json
)

-- The original pipeline is untouched
check(pipeline_node_options(p, "raw").serializer == "arrow")
check(pipeline_node_options(p, "report").serializer == "default")

info_r = pipeline_node_options(q_all, "heavy_r")
check(info_r.runtime == "R")
check(info_r.serializer == "json")
check(expect_in("src/functions.R", info_r.functions))
check(expect_in("config.yaml", info_r.include))
check(info_r.env_vars.GLOBAL_FLAG == "1")
-- per-node env var keys survive the merge
check(info_r.env_vars.RN_MODE == "fast")

print("✓ unscoped merge applied to all nodes; original pipeline unchanged")

-- ---------------------------------------------------------------------------
-- 3. runtimes scoping — only R nodes get the serializer
-- ---------------------------------------------------------------------------
q_r = set_pipeline_global_options(p, runtimes = ["rn"], serializer = ^csv)
check(pipeline_node_options(q_r, "heavy_r").serializer == "csv")
check(pipeline_node_options(q_r, "heavy_py").serializer == "json")
check(pipeline_node_options(q_r, "report").serializer == "default")

print("✓ runtimes scope: only R nodes switched to csv")

-- ---------------------------------------------------------------------------
-- 4. nodes scoping — exactly the listed nodes
-- ---------------------------------------------------------------------------
q_n = set_pipeline_global_options(p, nodes = ["say_hi"], noop = true)
check(pipeline_node_options(q_n, "say_hi").noop == true)
-- heavy_py is not in the nodes list, so its construct-time noop = false survives
check(pipeline_node_options(q_n, "heavy_py").noop == false)

print("✓ nodes scope: only the listed node was affected")

-- ---------------------------------------------------------------------------
-- 5. Union of nodes and runtimes scopes
-- ---------------------------------------------------------------------------
q_u = set_pipeline_global_options(p, nodes = ["report"], runtimes = ["pyn"], noop = true)
check(pipeline_node_options(q_u, "report").noop == true)
check(pipeline_node_options(q_u, "heavy_py").noop == true)
-- say_hi is neither the listed node nor the pyn runtime, so it keeps noop = false
check(pipeline_node_options(q_u, "say_hi").noop == false)

print("✓ union scope: report (node) + heavy_py (Python runtime) were no-oped")

-- ---------------------------------------------------------------------------
-- 6. Empty-list semantics
-- ---------------------------------------------------------------------------
-- Explicit empty `nodes` targets no nodes: nothing changes.
q_e = set_pipeline_global_options(p, nodes = [], serializer = ^json)
check(pipeline_node_options(q_e, "report").serializer == "default")
check(pipeline_node_options(q_e, "heavy_r").serializer == "arrow")

-- Empty `nodes` combined with `runtimes` still targets the runtime's nodes.
q_e2 = set_pipeline_global_options(p, nodes = [], runtimes = ["rn"], serializer = ^csv)
check(pipeline_node_options(q_e2, "heavy_r").serializer == "csv")
check(pipeline_node_options(q_e2, "report").serializer == "default")

print("✓ empty-list semantics: nodes = [] targets no nodes, runtimes still apply")

-- ---------------------------------------------------------------------------
-- 7. Hard overrides: shell / shell_args / flake, plus dependency prepend
-- ---------------------------------------------------------------------------
q_sh = set_pipeline_global_options(p, nodes = ["say_hi"], shell = "zsh", shell_args = "-e")
check(pipeline_node_options(q_sh, "say_hi").shell == "zsh")
check(expect_in("-e", pipeline_node_options(q_sh, "say_hi").shell_args))

q_d = set_pipeline_global_options(p, dependencies = ["raw"])
check(expect_pipeline(q_d))

print("✓ shell override and dependency prepend applied cleanly")

-- ---------------------------------------------------------------------------
-- 8. Explicit TypeErrors instead of silent no-ops
-- ---------------------------------------------------------------------------
check(expect_error(set_pipeline_global_options(p, nodes = ["nope"], noop = true), class = "TypeError"))
check(expect_error(set_pipeline_global_options(p, runtimes = ["Julia"], serializer = ^json), class = "TypeError"))
check(expect_error(set_pipeline_global_options(p, bogus = 1), class = "TypeError"))
check(expect_error(pipeline_node_options(p, "nope"), class = "TypeError"))
check(expect_error(pipeline_node_options(p = p, "report"), class = "TypeError"))

print("✓ unknown nodes, unmatched runtimes, and unknown args raise TypeErrors")

-- ---------------------------------------------------------------------------
-- 9. End-to-end: the base pipeline and a scoped variant populate and build
-- ---------------------------------------------------------------------------
populate_pipeline(p, build = true, verbose = 1)
populate_pipeline(q_r, build = true, verbose = 1)
pipeline_copy()

r_raw = read_node(p.raw)
check(expect_nrow(r_raw, 5))
check(read_node(p.report) == true)

print("✓ pipeline_global_options_t: all assertions passed")

-- Pipeline Diagnostics Test Demo
--
-- Validates that after build_pipeline(), diagnostics (errors, warnings,
-- filter_node, which_nodes, errored_nodes, read_pipeline) work correctly.
-- Uses build_pipeline to register targets so t_make() can resolve them,
-- and assert() to verify diagnostic expectations.

print("=== Pipeline Diagnostics Test ===")

-- ═══════════════════════════════════════════════════════════════
-- 1. Error pipeline: div-by-zero + downstream propagation
-- ═══════════════════════════════════════════════════════════════
p_err = pipeline {
    bad = 1 / 0
    downstream = bad + 1
}
build_pipeline(p_err, verbose=0)

-- Test: read_pipeline summary shows 2 errors
err_summary = read_pipeline(p_err).diagnostics.summary
assert(err_summary == "0 node(s) with warnings, 0 suppressed, 2 error(s), 0 recovered",
    "read_pipeline tracks 2 error nodes") |> print()

-- Test: read_node exposes structured error
bad_res = read_node(p_err.bad)
assert(bad_res.error.kind == "DivisionByZero",
    "read_node exposes DivisionByZero on bad node") |> print()

-- Test: filter_node(!is_na($diagnostics.error)) returns errored nodes
err_nodes = p_err |> filter_node(!is_na($diagnostics.error)) |> pipeline_nodes
assert(length(err_nodes) == 2 && contains(err_nodes, "bad") && contains(err_nodes, "downstream"),
    "filter_node finds 2 errored nodes") |> print()

-- Test: filter_node(is_na($diagnostics.error)) returns non-errored nodes
ok_nodes = p_err |> filter_node(is_na($diagnostics.error)) |> pipeline_nodes
assert(ok_nodes == [],
    "filter_node finds 0 non-errored nodes (all have errors)") |> print()

-- Test: which_nodes with diagnostics predicate
which_res = which_nodes(p_err, !is_na(diagnostics.error)) |> map(\(n) n.name)
assert(length(which_res) == 2 && contains(which_res, "bad") && contains(which_res, "downstream"),
    "which_nodes finds 2 errored nodes") |> print()

-- Test: errored_nodes convenience wrapper
errored = errored_nodes(p_err) |> map(\(n) n.name)
assert(length(errored) == 2 && contains(errored, "bad") && contains(errored, "downstream"),
    "errored_nodes finds 2 errored nodes") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 2. Warning pipeline: filter with NAs produces warnings
-- ═══════════════════════════════════════════════════════════════
p_warn = pipeline {
    data = to_dataframe([[x: 1], [x: NA], [x: 3]])
    filtered = filter(data, $x > 1)
    count = nrow(filtered)
}
build_pipeline(p_warn, verbose=0)

-- Test: read_pipeline summary shows 1 warning
warn_summary = read_pipeline(p_warn).diagnostics.summary
assert(warn_summary == "1 node(s) with warnings, 0 suppressed, 0 error(s), 0 recovered",
    "read_pipeline summarizes 1 warning origin") |> print()

-- Test: downstream nodes inherit upstream warnings via inspect_node
downstream_sources = inspect_node(p_warn.count).warnings |> map(\(w) w.source)
assert(downstream_sources == ["filtered"],
    "inspect_node shows upstream inherited warnings with correct source") |> print()

-- Test: warning_msg on downstream node includes ancestor provenance
count_warn_msg = warning_msg(p_warn.count)
assert(contains(count_warn_msg, "Ancestor node 'filtered' reported following warning"),
    "warning_msg on downstream node prefixes ancestor node name") |> print() 

-- Test: warning_msg on computed node
warn_msg_val = warning_msg(p_warn.filtered)
assert(warn_msg_val != "",
    "warning_msg returns non-empty message for filtered node") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 3. Pipeline node access via read_node
-- ═══════════════════════════════════════════════════════════════
p_math = pipeline {
    x = 10
    y = 20
    total = x + y
}
build_pipeline(p_math, verbose=0)

assert(read_node(p_math.x) == 10, "read_node(p.x) returns 10") |> print()
assert(read_node(p_math.total) == 30, "read_node(p.total) returns 30") |> print()

-- Test: pipeline_node() gets specific node value
node_val = pipeline_node(p_math, "total")
assert(node_val == 30, "pipeline_node(p, 'total') returns 30") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 4. Pipeline with pipe operator and functions
-- ═══════════════════════════════════════════════════════════════
p_pipe = pipeline {
    a = 5
    b = a |> \(xx) xx * 2
}
build_pipeline(p_pipe, verbose=0)
assert(read_node(p_pipe.b) == 10, "pipeline with pipe operator: read_node(p.b) == 10") |> print()

p_func = pipeline {
    data = [1, 2, 3]
    total = sum(data)
    count = length(data)
}
build_pipeline(p_func, verbose=0)
assert(read_node(p_func.total) == 6, "pipeline with function calls: read_node(p.total) == 6") |> print()
assert(read_node(p_func.count) == 3, "pipeline nodes available: read_node(p.count) == 3") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 5. Out-of-order and chain dependencies
-- ═══════════════════════════════════════════════════════════════
p_deps = pipeline {
    result = x + y
    x = 3
    y = 7
}
build_pipeline(p_deps, verbose=0)
assert(read_node(p_deps.result) == 10, "out-of-order deps resolved: read_node(p.result) == 10") |> print()

p_chain = pipeline {
    a = 1
    b = a + 1
    c = b + 1
    d = c + 1
}
build_pipeline(p_chain, verbose=0)
assert(read_node(p_chain.d) == 4, "chain deps resolved: read_node(p.d) == 4") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 6. Deterministic execution
-- ═══════════════════════════════════════════════════════════════
p1 = pipeline { a = 5; b = a * 2; c = b + 1 }
p2 = pipeline { a = 5; b = a * 2; c = b + 1 }
build_pipeline(p1, verbose=0)
build_pipeline(p2, verbose=0)
assert(read_node(p1.c) == read_node(p2.c), "pipelines execute deterministically") |> print()


-- ═══════════════════════════════════════════════════════════════
-- 7. Re-run preserves values
-- ═══════════════════════════════════════════════════════════════
p_rerun = pipeline { a = 10; b = 20; total = a + b }
build_pipeline(p_rerun, verbose=0)
assert(read_node(p_rerun.total) == 30, "re-run preserves cached values") |> print()

p_rerun2 = pipeline { a = 10; b = 20; total = a + b }
build_pipeline(p_rerun2, verbose=0)
assert(read_node(p_rerun2.total) == 30, "re-run deterministic execution") |> print()


print("")
print("=== All pipeline diagnostics tests passed ===")

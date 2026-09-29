outer_val = 41
inc = \(n: Int -> Int) n + 1

p = pipeline {
  -- 1. Outer data inlines as a frozen literal
  frozen = node(command = outer_val + 1)

  -- 2. Block-local bindings stay local
  shadowed = node(command = { outer_val = 1; outer_val + 1 })

  -- 3. Quoted code runs later, at node runtime
  via_quoted = node(command = eval(to_expr({ outer_val = 7; outer_val * 2 })))

  -- 4. Bare outer lambdas stay symbolic: the sandbox has no such binding,
  --    so the node captures the failure as a first-class error instead
  via_lambda = node(command = inc(41))

  -- 5. Calling a bare symbol fails fast with an explicit TypeError
  sym_call = node(command = default("x"))

  -- 6. Aggregate verdict (sibling values are node inputs at runtime)
  report = node(command = {
    ok1 = frozen == 42
    ok2 = shadowed == 2
    ok3 = via_quoted == 14
    ok4 = is_error(via_lambda) && error_code(via_lambda) == "NameError"
    ok5 = is_error(sym_call) && error_code(sym_call) == "TypeError"
    [test: "capture_transparency", passed: ok1 && ok2 && ok3 && ok4 && ok5]
  })
}

print("Running capture_transparency_t -- what crosses the node boundary...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
  print("[ERROR]", error_message(res))
  exit(1)
}

rep = read_node(p.report)
print(rep)
assert(rep.passed, "capture_transparency_t: report did not pass")

print("✓ capture_transparency_t: all assertions passed")

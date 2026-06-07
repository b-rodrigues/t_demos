p = pipeline {
  -- 1. Shadow builtins: assigning to reserved keywords
  test_shadow_builtins = node(command = {
    r1 = eval(to_expr({ sum = 42 }))
    r2 = eval(to_expr({ print := 99 }))
    ok1 = is_error(r1)
    ok2 = is_error(r2)
    [test: "shadow_builtins", passed: ok1 && ok2,
     sum_code: if (is_error(r1)) { error_code(r1) } else { "none" },
     print_code: if (is_error(r2)) { error_code(r2) } else { "none" }]
  })

  -- 2. Type mismatch in arithmetic
  test_type_mismatch_arith = node(command = {
    r1 = 1 + "hello"
    r2 = [1, 2] + 3
    r3 = "a" > 5
    ok1 = is_error(r1)
    ok2 = is_error(r2)
    ok3 = is_error(r3)
    [test: "type_mismatch_arith", passed: ok1 && ok2 && ok3]
  })

  -- 3. Type mismatch in function application
  test_type_mismatch_func = node(command = {
    r1 = head(42)
    r2 = sum("hello")
    r3 = mean(true)
    ok1 = is_error(r1)
    ok2 = is_error(r2)
    ok3 = is_error(r3)
    [test: "type_mismatch_func", passed: ok1 && ok2 && ok3]
  })

  -- 4. Name suggestions (Levenshtein)
  test_name_suggestions = node(command = {
    r1 = prnt("hi")
    r2 = slect([1, 2, 3])
    r3 = flter(1)
    ok1 = is_error(r1)
    ok2 = is_error(r2)
    ok3 = is_error(r3)
    msg1 = if (is_error(r1)) { error_msg(r1) } else { "" }
    has_suggest = str_detect(msg1, "print")
    [test: "name_suggestions", passed: ok1 && ok2 && ok3 && has_suggest, msg: msg1]
  })

  -- 5. Division by zero + pipe short-circuit
  test_div_zero_short = node(command = {
    result = (1 / 0) |> \(x) x + 1
    ok = is_error(result)
    [test: "div_zero_short", passed: ok, code: if (ok) { error_code(result) } else { "none" }]
  })

  -- 6. Division by zero + maybe-pipe recovery
  test_div_zero_recover = node(command = {
    result = (1 / 0) ?|> \(x) if (is_error(x)) { 0 } else { x }
    ok = !is_error(result) && result == 0
    [test: "div_zero_recover", passed: ok, value: result]
  })

  -- 7. Deeply nested lists using seq + map
  test_deep_nesting = node(command = {
    nested = seq(1, 30) |> map(\(x) [x, x * 2])
    passed = length(nested) == 30
    [test: "deep_nesting", passed: passed, depth: length(nested)]
  })

  -- 8. Error chain
  test_error_chain = node(command = {
    e1 = error("E1", "first")
    e2 = error("E2", "second")
    e3 = error("E3", "third")
    chain = error_chain(e1, e2, e3)
    len = length(chain)
    first_code = error_code(get(chain, 0))
    last_msg = error_msg(get(chain, 2))
    [test: "error_chain", passed: len == 3 && first_code == "E1" && last_msg == "third",
     chain_length: len, first: first_code, last: last_msg]
  })

  -- 9. rm() on a user-defined variable
  test_rm = node(command = {
    x = 42
    result = rm("x")
    ok = is_na(result)
    [test: "rm_variable", passed: ok]
  })

  -- 10. rm() on builtin keyword
  test_rm_builtin = node(command = {
    result = rm("print")
    ok = is_na(result) || is_error(result)
    [test: "rm_builtin", passed: ok, result_type: type(result)]
  })

  -- 11. Pattern match on NA
  test_match_na = node(command = {
    r = match(NA) {
      Int => "int",
      Float => "float",
      Bool => "bool",
      _ => "fallback"
    }
    [test: "match_na", passed: r == "fallback", result: r]
  })

  -- 12. Pattern match on Error
  test_match_error = node(command = {
    r = match(error("MY_CODE", "something broke")) {
      Error { code: c, msg: m } => str_sprintf("caught %s: %s", c, m),
      _ => "no match"
    }
    [test: "match_error", passed: r == "caught MY_CODE: something broke", result: r]
  })

  -- 13. Reassignment across types
  test_reassignment = node(command = {
    a = 42
    a := "hello"
    a := [1, 2, 3]
    ok1 = a == [1, 2, 3]
    a := [x: 10]
    ok2 = type(a) == "Dict"
    [test: "reassignment", passed: ok1 && ok2]
  })

  -- 14. Large pipe chain with seq
  test_large_pipe = node(command = {
    result = seq(1, 30)
      |> map(\(x) x * 2)
      |> map(\(x) x + 1)
      |> map(\(x) x * x)
      |> length()
    [test: "large_pipe", passed: result == 30, result: result]
  })

  -- 15. Factor edge cases
  test_factor_edges = node(command = {
    f1 = to_factor(["a", "b", "a"], levels = ["a", "b", "c"])
    r1 = levels(f1)
    ok1 = length(r1) == 3
    f2 = to_factor(["low", "high", "medium"], levels = ["low", "medium", "high"], ordered = true)
    ok2 = !is_error(f2)
    [test: "factor_edges", passed: ok1 && ok2]
  })

  -- Validation
  validation = node(command = {
    results = [
      test_shadow_builtins,
      test_type_mismatch_arith,
      test_type_mismatch_func,
      test_name_suggestions,
      test_div_zero_short,
      test_div_zero_recover,
      test_deep_nesting,
      test_error_chain,
      test_rm,
      test_rm_builtin,
      test_match_na,
      test_match_error,
      test_reassignment,
      test_large_pipe,
      test_factor_edges
    ]
    failures = results |> filter($passed == false)
    n_fail = nrow(failures)
    if (n_fail > 0) {
      print("FAILURES:")
      print(failures)
      assert(n_fail == 0, str_sprintf("variable_vice_t: %d tests failed", n_fail))
    }
    [status: "ok", total: 15, passed: 15 - n_fail, failures: n_fail]
  })
}

print("Running variable_vice_t -- value and variable stress test...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
  print(res)
  exit(1)
}

print("=== Individual Test Results ===")
print("--- test_shadow_builtins ---"); print(read_node(p.test_shadow_builtins))
print("--- test_type_mismatch_arith ---"); print(read_node(p.test_type_mismatch_arith))
print("--- test_type_mismatch_func ---"); print(read_node(p.test_type_mismatch_func))
print("--- test_name_suggestions ---"); print(read_node(p.test_name_suggestions))
print("--- test_div_zero_short ---"); print(read_node(p.test_div_zero_short))
print("--- test_div_zero_recover ---"); print(read_node(p.test_div_zero_recover))
print("--- test_deep_nesting ---"); print(read_node(p.test_deep_nesting))
print("--- test_error_chain ---"); print(read_node(p.test_error_chain))
print("--- test_rm ---"); print(read_node(p.test_rm))
print("--- test_rm_builtin ---"); print(read_node(p.test_rm_builtin))
print("--- test_match_na ---"); print(read_node(p.test_match_na))
print("--- test_match_error ---"); print(read_node(p.test_match_error))
print("--- test_reassignment ---"); print(read_node(p.test_reassignment))
print("--- test_large_pipe ---"); print(read_node(p.test_large_pipe))
print("--- test_factor_edges ---"); print(read_node(p.test_factor_edges))

report = read_node(p.validation)
print("=== Summary ===")
print(report)
assert(!is_error(report), "validation node should not error")
assert(report.failures == 0, str_sprintf("%d variable tests failed!", report.failures))
print("All variable vice tests passed!")

import colcraft
import dataframe

p = pipeline {
  -- 1. Empty dataframe
  test_empty = node(command = {
    df = to_dataframe([])
    [test: "empty_df", passed: nrow(df) == 0 and ncol(df) == 0, rows: nrow(df), cols: ncol(df)]
  })

  -- 2. All-NA columns (one per type)
  test_all_na = node(command = {
    df = to_dataframe([
      [i: na_int(), f: na_float(), b: na_bool(), s: na_string()],
      [i: na_int(), f: na_float(), b: na_bool(), s: na_string()]
    ])
    all_na = is_na(pull(df, $i)) and is_na(pull(df, $f)) and
             is_na(pull(df, $b)) and is_na(pull(df, $s))
    [test: "all_na_df", passed: all_na and nrow(df) == 2 and ncol(df) == 4, rows: nrow(df), cols: ncol(df)]
  })

  -- 3. Single cell (1 row x 1 col)
  test_single_cell = node(command = {
    df = to_dataframe([[x: 42]])
    val = pull(df, $x) |> get(0)
    [test: "single_cell", passed: nrow(df) == 1 and ncol(df) == 1 and val == 42, rows: nrow(df), cols: ncol(df), value: val]
  })

  -- 4. Duplicate column names: rename to an existing name
  test_dup_colnames = node(command = {
    df = to_dataframe([[a: 1, b: 2], [a: 3, b: 4]])
    risky = rename(df, a = $b)
    risky ?|> \(r) {
      if (is_error(r)) {
        [test: "dup_colnames", passed: true, status: "error", code: error_code(r)]
      } else {
        [test: "dup_colnames", passed: ncol(r) == 2, status: "ok", cols: colnames(r)]
      }
    }
  })

  -- 5. Long column name in CSV
  test_long_colname = node(command = {
    long = seq(1, 100) |> map(\(x) to_string(x)) |> str_join(sep = "")
    header = str_join(["short,", long, "\n"])
    content = str_join([header, "1,2\n"])
    write_text(content, "long_col.csv")
    df = read_csv("long_col.csv")
    names = colnames(df)
    name_len = str_nchar(get(names, 1))
    [test: "long_colname", passed: name_len == 100, name_len: name_len]
  })

  -- 6. NA in filter predicate
  test_na_filter = node(command = {
    df = to_dataframe([
      [id: 1, val: 10.0],
      [id: 2, val: na_float()],
      [id: 3, val: 30.0]
    ])
    risky = df |> filter($val > 15)
    risky ?|> \(x) if (is_error(x)) {
      [test: "na_filter", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "na_filter", passed: nrow(x) == 1, status: "ok", rows: nrow(x)]
    }
  })

  -- 7. NA arithmetic in mutate
  test_na_arithmetic = node(command = {
    df = to_dataframe([
      [id: 1, val: na_float()],
      [id: 2, val: 5.0]
    ])
    risky = df |> mutate($new = $val + 1)
    risky ?|> \(x) if (is_error(x)) {
      [test: "na_arithmetic", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "na_arithmetic", passed: nrow(x) == 2, status: "ok"]
    }
  })

  -- 8. Type coercion: int + float in mutate
  test_coerce_mutate = node(command = {
    df = to_dataframe([
      [a: 1, b: 2.5],
      [a: 3, b: 4.5]
    ])
    risky = df |> mutate($c = $a + $b)
    risky ?|> \(x) if (is_error(x)) {
      [test: "coerce_mutate", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "coerce_mutate", passed: nrow(x) == 2 and ncol(x) == 3, status: "ok", rows: nrow(x)]
    }
  })

  -- 9. bind_rows with mismatched types
  test_coerce_bind = node(command = {
    df1 = to_dataframe([[x: 1, y: "a"]])
    df2 = to_dataframe([[x: "two", y: 2]])
    risky = bind_rows(df1, df2)
    risky ?|> \(x) if (is_error(x)) {
      [test: "coerce_bind", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "coerce_bind", passed: nrow(x) == 2, status: "ok", rows: nrow(x)]
    }
  })

  -- 10. pivot_wider with duplicate keys
  test_pivot_dup_keys = node(command = {
    df = to_dataframe([
      [id: 1, key: "k", val: 10],
      [id: 1, key: "k", val: 20]
    ])
    risky = df |> pivot_wider(names_from = $key, values_from = $val)
    risky ?|> \(x) if (is_error(x)) {
      [test: "pivot_dup_keys", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "pivot_dup_keys", passed: nrow(x) == 1, status: "ok", rows: nrow(x)]
    }
  })

  -- 11. pivot_longer basic sanity
  test_pivot_longer = node(command = {
    df = to_dataframe([
      [id: 1, a: 10, b: 20],
      [id: 2, a: 30, b: 40]
    ])
    risky = df |> pivot_longer(cols = [$a, $b], names_to = "key", values_to = "val")
    risky ?|> \(x) if (is_error(x)) {
      [test: "pivot_longer", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "pivot_longer", passed: nrow(x) == 4 and ncol(x) == 3, status: "ok", rows: nrow(x)]
    }
  })

  -- 12. group_by with NA key
  test_group_by_na = node(command = {
    df = to_dataframe([
      [g: "a", v: 1],
      [g: na_string(), v: 2],
      [g: "b", v: 3]
    ])
    risky = df |> group_by($g) |> summarize(total = sum($v, na_rm = true))
    risky ?|> \(x) if (is_error(x)) {
      [test: "group_by_na", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "group_by_na", passed: nrow(x) == 3, status: "ok", rows: nrow(x)]
    }
  })

  -- 13. Empty grouped summarize
  test_empty_grouped = node(command = {
    df = to_dataframe([
      [g: "a", v: 1],
      [g: "b", v: 2]
    ])
    risky = df
      |> filter($g == "nonexistent")
      |> group_by($g)
      |> summarize(total = sum($v, na_rm = true))
    risky ?|> \(x) if (is_error(x)) {
      [test: "empty_grouped", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "empty_grouped", passed: nrow(x) == 0, status: "ok", rows: nrow(x)]
    }
  })

  -- 14. Zero-column dataframe via select with no args
  test_zero_cols = node(command = {
    df = to_dataframe([[a: 1, b: 2]])
    risky = df |> select()
    risky ?|> \(x) if (is_error(x)) {
      [test: "zero_cols", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "zero_cols", passed: ncol(x) == 0, status: "ok", cols: ncol(x)]
    }
  })

  -- Validation
  validation = node(command = {
    results = [
      test_empty,
      test_all_na,
      test_single_cell,
      test_dup_colnames,
      test_long_colname,
      test_na_filter,
      test_na_arithmetic,
      test_coerce_mutate,
      test_coerce_bind,
      test_pivot_dup_keys,
      test_pivot_longer,
      test_group_by_na,
      test_empty_grouped,
      test_zero_cols
    ]
    failures = results |> filter($passed == false)
    n_fail = nrow(failures)
    if (n_fail > 0) {
      print("FAILURES:")
      print(failures)
      assert(n_fail == 0, str_sprintf("dataframe_abyss_t: %d tests failed", n_fail))
    }
    [status: "ok", total: 14, passed: 14 - n_fail, failures: n_fail]
  })
}

print("Running dataframe_abyss_t — data frame corner case stress test...")
res = build_pipeline(p, verbose = 1)
if (is_error(res)) {
  print(res)
  exit(1)
}

report = read_node(p.validation)
print("=== DataFrame Abyss Results ===")
print(report)
assert(not is_error(report), "validation node should not error")
assert(report.failures == 0, str_sprintf("%d DataFrame tests failed!", report.failures))
print("All dataframe abyss tests passed!")

import colcraft
import dataframe

p = pipeline {
  -- 1. Empty file (0 bytes)
  test_empty = node(command = {
    write_text("", "empty.csv")
    result = read_csv("empty.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "empty_file", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "empty_file", passed: false, status: "unexpected_ok", rows: nrow(x)]
    }
  })

  -- 2. Header only -- no data rows
  test_header_only = node(command = {
    write_text("a,b,c\n", "header_only.csv")
    df = read_csv("header_only.csv")
    [test: "header_only", passed: nrow(df) == 0 && ncol(df) == 3, rows: nrow(df), cols: ncol(df)]
  })

  -- 3. Ragged rows -- column count mismatch
  test_ragged = node(command = {
    write_text("a,b,c\n1,2\n3,4,5,6\n7,8,9,10,11", "ragged.csv")
    result = read_csv("ragged.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "ragged_rows", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "ragged_rows", passed: false, status: "unexpected_ok", rows: nrow(x)]
    }
  })

  -- 4. Trailing/leading/double commas
  test_weird_delimiters = node(command = {
    content = str_join([
      "a,b,c\n",
      "1,2,\n",
      ",4,5\n",
      "6,,7\n"
    ])
    write_text(content, "weird_delim.csv")
    result = read_csv("weird_delim.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "weird_delimiters", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "weird_delimiters", passed: true, status: "ok", rows: nrow(x), cols: ncol(x)]
    }
  })

  -- 5. BOM prefix
  test_bom = node(command = {
    content = str_join(["\xef\xbb\xbf", "a,b\n1,2\n"])
    write_text(content, "bom.csv")
    result = read_csv("bom.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "bom_prefix", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "bom_prefix", passed: true, status: "ok", rows: nrow(x), cols: ncol(x)]
    }
  })

  -- 6. Weird column names
  test_weird_colnames = node(command = {
    content = str_join([
      "\"%growth\",\"$price\",\"€uro\",\"col name\",\"123start\",\"\",a,a\n",
      "1,2,3,4,5,6,7,8\n"
    ])
    write_text(content, "weird_colnames.csv")
    result = read_csv("weird_colnames.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "weird_colnames", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "weird_colnames", passed: ncol(x) == 8, status: "ok", cols: ncol(x), names: colnames(x)]
    }
  })

  -- 7. Mixed-type column: int then string then NA
  test_mixed_types = node(command = {
    content = str_join([
      "val\n",
      "42\n",
      "hello\n",
      "\n"
    ])
    write_text(content, "mixed_types.csv")
    df = read_csv("mixed_types.csv")
    [test: "mixed_types", passed: nrow(df) == 3, status: "ok", rows: nrow(df)]
  })

  -- 8. Unicode values in data
  test_unicode_values = node(command = {
    content = str_join([
      "label,value\n",
      "\"café\",1\n",
      "\"naïve\",2\n",
      "\"中文\",3\n",
      "\"😀\",4\n"
    ])
    write_text(content, "unicode.csv")
    df = read_csv("unicode.csv")
    [test: "unicode_values", passed: nrow(df) == 4, status: "ok", rows: nrow(df)]
  })

  -- 9. Quoted fields with embedded newlines
  test_quoted_newlines = node(command = {
    content = str_join([
      "id,note\n",
      "1,\"line1\n",
      "line2\"\n",
      "2,\"single\"\n"
    ])
    write_text(content, "newlines.csv")
    result = read_csv("newlines.csv")
    result ?|> \(x) if (is_error(x)) {
      [test: "quoted_newlines", passed: true, status: "error", code: error_code(x)]
    } else {
      [test: "quoted_newlines", passed: nrow(x) == 2, status: "ok", rows: nrow(x)]
    }
  })

  -- 10. Tab separator
  test_tab_sep = node(command = {
    content = str_join(["a\tb\tc\n", "1\t2\t3\n", "4\t5\t6\n"])
    write_text(content, "tab.csv")
    df = read_csv("tab.csv", separator = "\t")
    [test: "tab_separator", passed: nrow(df) == 2 && ncol(df) == 3, rows: nrow(df), cols: ncol(df)]
  })

  -- 11. Semicolon separator
  test_semicolon_sep = node(command = {
    content = str_join(["a;b;c\n", "1;2;3\n", "4;5;6\n"])
    write_text(content, "semicolon.csv")
    df = read_csv("semicolon.csv", separator = ";")
    [test: "semicolon_separator", passed: nrow(df) == 2 && ncol(df) == 3, rows: nrow(df), cols: ncol(df)]
  })

  -- 12. clean_colnames on weird names
  test_clean_colnames = node(command = {
    content = str_join([
      "\"%growth\",\"$price\",\"€uro\",\"col name\",\"123start\"\n",
      "1,2,3,4,5\n"
    ])
    write_text(content, "clean_me.csv")
    df = read_csv("clean_me.csv", clean_colnames = true)
    names = colnames(df)
    passed = ncol(df) == 5
    [test: "clean_colnames", passed: passed, status: "ok", names: names]
  })

  -- 13. skip_lines + skip_header
  test_skip = node(command = {
    content = str_join([
      "garbage line\n",
      "more garbage\n",
      "a,b,c\n",
      "1,2,3\n",
      "4,5,6\n"
    ])
    write_text(content, "skip.csv")
    df = read_csv("skip.csv", skip_lines = 2, skip_header = true)
    [test: "skip_options", passed: nrow(df) == 2 && ncol(df) == 3, rows: nrow(df), cols: ncol(df)]
  })

  -- Validation report: collect all results and assert
  validation = node(command = {
    results = [
      test_empty,
      test_header_only,
      test_ragged,
      test_weird_delimiters,
      test_bom,
      test_weird_colnames,
      test_mixed_types,
      test_unicode_values,
      test_quoted_newlines,
      test_tab_sep,
      test_semicolon_sep,
      test_clean_colnames,
      test_skip
    ]
    failures = results |> filter($passed == false)
    n_fail = nrow(failures)
    if (n_fail > 0) {
      print("FAILURES:")
      print(failures)
      assert(n_fail == 0, str_sprintf("csv_carnage_t: %d tests failed", n_fail))
    }
    [status: "ok", total: 13, passed: 13 - n_fail, failures: n_fail]
  })
}

print("Running csv_carnage_t -- malformed CSV stress test...")
res = build_pipeline(p, verbose = 1)
if (is_error(res)) {
  print(res)
  exit(1)
}

report = read_node(p.validation)
print("=== CSV Carnage Results ===")
print(report)
assert(!is_error(report), "validation node should not error")
assert(report.failures == 0, str_sprintf("%d CSV tests failed!", report.failures))
print("All CSV carnage tests passed!")

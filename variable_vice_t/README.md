# variable_vice_t

Stress test the T language runtime with corner cases in values, variables, and operations.

Tests 15 edge-case scenarios:
1. **Shadow builtins** — assignment to reserved keywords
2. **Type mismatch: arithmetic** — `1 + "hello"`, `[1,2] + 3`
3. **Type mismatch: functions** — `head(42)`, `sum("hello")`
4. **Name suggestions** — typo `prnit` suggests `print`
5. **Div-by-zero + pipe short-circuit** — `|>` stops at error
6. **Div-by-zero + maybe-pipe recovery** — `?|>` forwards error for handling
7. **Deeply nested lists** — 30-level deep list access
8. **Error chain** — compose 5 errors, inspect chain
9. **rm() nonexistent** — error from removing undefined variable
10. **rm() builtin** — error from removing reserved keyword
11. **Pattern match: NA** — match on missing value
12. **Pattern match: Error** — destructure error values
13. **Reassignment** — `:=` across types
14. **Large pipe chain** — 30+ chained operations
15. **Factor edge cases** — empty/NA/duplicate levels

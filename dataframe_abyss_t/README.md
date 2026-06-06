# dataframe_abyss_t

Stress test T data frames with extreme shapes and broken structures.

Tests 14 edge-case scenarios:
1. **Empty dataframe** — `to_dataframe([])`, nrow=0
2. **All-NA columns** — typed NAs (int, float, bool, string) in every column
3. **Single cell** — 1 row × 1 col
4. **Duplicate colnames** — same name used twice
5. **500-char column name** — extremely long identifier
6. **NA in filter** — `filter()` on NA-containing column
7. **NA arithmetic** — mutate with `$na_col + 1`
8. **Type coercion: mutate** — int + float column
9. **Type coercion: bind_rows** — mismatched column types
10. **pivot_wider duplicate keys** — expected error
11. **pivot_longer NA keys** — NA in key column
12. **group_by NA key** — grouping on NA column
13. **Empty grouped summarize** — filter to zero then group + summarize
14. **Zero columns** — dataframe with 0 columns

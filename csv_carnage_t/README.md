# csv_carnage_t

Stress test `read_csv` with malformed CSVs.

Tests 13 edge-case scenarios:
1. **Empty file** (0 bytes) — expects `FileError`
2. **Header only** — no data rows, nrow=0 but ncol preserved
3. **Ragged rows** — rows with fewer/more columns than header
4. **Trailing/leading/double commas** — weird delimiter combos
5. **BOM prefix** — UTF-8 BOM bytes at file start
6. **Weird column names** — `%`, `$`, `€`, spaces, leading digits, empty, duplicates
7. **Mixed-type columns** — int → string → NA in same column
8. **Unicode values** — café, naïve, 中文, emoji
9. **Quoted newlines** — multi-line values inside quotes
10. **Tab separator** — `separator = "\t"`
11. **Semicolon separator** — `separator = ";"`
12. **`clean_colnames` stress** — clean_colnames=true on intentionally weird names
13. **`skip_lines` + `skip_header`** — combinations

All CSVs are generated inline via `write_text()` and read back with `read_csv()`.

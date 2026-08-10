# check_fix_diff_t

Demonstrates T's structural checker (`t check`), mechanical fix application (`t fix`), and content-addressed build diffing (`t diff`).

## Quick start

```bash
t run src/pipeline.t
```

## What this demo shows

### 1. `t check --schema` — static pipeline validation

```bash
t check --schema src/pipeline.t
```

Runs the full evaluator but short-circuits Nix builds. Validates pipeline DAG structure, node dependency references, and column references against the inferred schema. Completes instantly without requiring Nix or runtime dependencies.

### 2. `t fix` — mechanical fix application

If a structural diagnostic has a suggested fix (e.g. a `Rename_column` for a misspelled column reference), `t fix` can apply it:

```bash
# Preview what would change
t fix --dry-run src/pipeline.t

# Apply the fix
t fix src/pipeline.t
```

**Try it yourself:**

1. In `src/pipeline.t`, change `filter($amount > 0)` to `filter($amout > 0)` (typo).
2. Run `t check --schema src/pipeline.t` — you'll see a column-reference diagnostic.
3. Run `t fix src/pipeline.t` — it renames the column back.
4. Revert with `git checkout src/pipeline.t`.

### 3. Runtime contract checks (testcraft)

After the pipeline builds, runtime `expect_*` assertions verify the output:

```t
assert(expect_colnames(clean_df, ["id", "amount", "date", "status"]), "clean has expected columns")
assert(expect_column_types(clean_df, [amount: "Float"]), "amount column is a double")
assert(expect_no_na(clean_df, "amount"), "amount column has no NAs")
```

### 4. `t diff` — content-addressed build diffing

After building a pipeline at least twice, `t diff` compares per-node Nix content hashes between builds:

```bash
t diff src/pipeline.t              # compare last two builds
t diff src/pipeline.t --json       # structured JSON output
t diff src/pipeline.t --log-a 2 --log-b 1  # compare specific build ranks
```

Or programmatically from T:

```t
diff_summary(p)  -- returns a DataFrame with columns: name, status, hash_a, hash_b
```

## Files

| File | Description |
|------|-------------|
| `src/pipeline.t` | Main pipeline script with structural validation and runtime contract checks |
| `data/sales.csv` | Input data (5 rows, 4 columns) |
| `tproject.toml` | Project config (T-only, no R/Python deps) |

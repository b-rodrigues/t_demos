# check_fix_diff_t

Demonstrates T's static contract system (`expect()`), mechanical fix application (`t fix`), and content-addressed build diffing (`t diff`).

## Quick start

```bash
t run src/pipeline.t
```

## What this demo shows

### 1. `expect()` contracts

The `clean` node declares three contract types:

| Contract | Syntax | Checked by |
|----------|--------|------------|
| Column presence | `columns = ["id", ...]` | `t check --schema` (static) |
| Type | `amount ~ double()` | `t check --schema` (static) |
| Null-rate | `null_rate("amount") < 0.05` | runtime (warning at check time) |

### 2. `t check --schema` — static contract validation

```bash
t check --schema src/pipeline.t
```

Runs the full evaluator but short-circuits Nix builds. Validates pipeline DAG structure, column references, and `expect()` contracts against the inferred Arrow schema. Completes instantly without requiring Nix or runtime dependencies.

### 3. `t fix` — mechanical fix application

If a type contract fails (e.g., `amount ~ string()` when the schema infers `double`), `t check --schema` emits a `contract_violation` diagnostic with a `suggested_fix` of kind `cast`. `t fix` applies it:

```bash
# Preview what would change
t fix --dry-run src/pipeline.t

# Apply the fix (inserts |> mutate($amount = as.string($amount)) before the expect())
t fix src/pipeline.t

# Verify the fix worked
t check --schema src/pipeline.t
```

**Try it yourself:**

1. In `src/pipeline.t`, change `amount ~ double()` to `amount ~ string()` in the `expect()` call.
2. Run `t check --schema src/pipeline.t` — you'll see a `contract_violation` error with a `cast` suggested_fix.
3. Run `t fix src/pipeline.t` — it inserts a `mutate()` call to cast the column.
4. Run `t check --schema src/pipeline.t` again — the contract passes.
5. Revert with `git checkout src/pipeline.t`.

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
| `src/pipeline.t` | Main pipeline script with `expect()` contracts |
| `data/sales.csv` | Input data (5 rows, 4 columns) |
| `tproject.toml` | Project config (T-only, no R/Python deps) |

# Testcraft Expectations Demo (`testcraft_expectations_t`)

This demonstration showcases **all Testcraft expectation primitives** (`expect_*`) available in the T language for data quality assertions, unit testing, and pipeline DAG structural verification.

## Features & Primitives Covered

- **Pipeline Verification & Assertion Nodes**: `check_raw` node returning named dictionaries of `assert(expect_*(...))` calls serialized as JSON (`serializer = ^json`)
- **Data Quality & Structure Assertions**: `expect_nrow`, `expect_ncol`, `expect_colnames`, `expect_fields`, `expect_in`, `expect_length`, `expect_no_na`, `expect_set_equal`, `expect_empty`
- **Range & Relational Assertions**: `expect_gt`, `expect_gte`, `expect_lt`, `expect_lte`, `expect_between`
- **String Pattern Assertions**: `expect_match` (regex matching), `expect_str_contains` (substring search)
- **Equality & Testcraft Meta Expectations**: `expect_equal`, `expect_pass`, `expect_fail`, `expect_msg`
- **Type & Logic Assertions**: `expect_type`, `expect_true`, `expect_false`, `expect_truthy`, `expect_falsy`
- **Condition & Error Verification**: `expect_error`, `expect_warning`
- **Expectation Summary Reporting**: `expect_summary` (summarizes list or dictionary of expectation/assertion results into a DataFrame with `check`, `status`, and `message` columns)
- **Pipeline DAG Structural Verification**: `expect_pipeline`, `expect_nodes`, `expect_dependency`, `expect_has_pattern`, `expect_runtime`, `expect_serializer`, `expect_deserializer`, `expect_noop`, `expect_computed`

## Running the Demo

```bash
cd testcraft_expectations_t
nix develop --command t run src/pipeline.t
```

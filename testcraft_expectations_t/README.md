# Testcraft Expectations Demo (`testcraft_expectations_t`)

This demonstration showcases **all Testcraft expectation primitives** (`expect_*`) available in the T language for data quality assertions, unit testing, and pipeline DAG structural verification.

## Features Covered

- **Pipeline Verification & Assertion Nodes**: `check_raw` node returning named dictionaries of `assert(expect_*(...))` calls serialized as JSON (`serializer = ^json`)
- **Pipeline DAG Structural Verification**: `expect_pipeline`, `expect_nodes`, `expect_dependency`, `expect_has_pattern`, `expect_runtime`, `expect_serializer`, `expect_deserializer`, `expect_noop`, `expect_computed`
- **Data Structure Assertions**: `expect_nrow`, `expect_ncol`, `expect_colnames`, `expect_fields`, `expect_in`, `expect_length`
- **Relational Assertions**: `expect_gt`, `expect_gte`, `expect_ge`, `expect_lt`, `expect_lte`, `expect_le`
- **Equality & Testcraft Meta Expectations**: `expect_equal`, `expect_pass`, `expect_fail`, `expect_msg`
- **Type & Logic Assertions**: `expect_type`, `expect_true`, `expect_false`, `expect_truthy`, `expect_falsy`
- **Condition & Error Verification**: `expect_error`, `expect_warning`

## Running the Demo

```bash
cd testcraft_expectations_t
nix develop --command t run src/pipeline.t
```

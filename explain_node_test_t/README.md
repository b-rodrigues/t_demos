# explain --node Test Demo

End-to-end validation of `t explain --node` output across error and warning
nodes.  The pipeline builds three nodes:

- **`t_ok`** (T) — a plain integer node that always succeeds (baseline).
- **`r_warn`** (R) — emits an R `warning()` to produce a captured pipeline warning.
- **`r_err`** (R) — calls `stop()` to produce a build error.

After the build, the CI workflow runs `t explain --node` in both JSON and
plain-text modes against each node and verifies the output shape.

## What is tested

| Node | JSON check | Plain-text check |
|:---|:---|:---|
| `t_ok` | `status: success`, empty `warnings` | "compiled/built successfully" |
| `r_warn` | `status: success`, populated `warnings` with `code`/`message` | "warning(s):" with warning text |
| `r_err` | `status: failed`, `error_code`, `message`, `node` | "Error Code:" + "Message:" |

In-memory diagnostics (`warning_msg`, `error_msg`, `read_node`) are also
verified in a separate step via `t run --unsafe`.

## Why a demo instead of a unit test

The existing CLI test (`test_cli.ml`) runs `t explain --node` in check mode,
which cannot produce diagnostic data (nodes are deferred, no build logs exist).
A real pipeline build is needed to generate build logs with error and warning
entries that `t explain --node` can read.  This demo provides that real build.

## Usage

```bash
t run src/pipeline.t
```

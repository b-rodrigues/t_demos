# Pipeline Report


## Overview

| Metric | Count |
|--------|-------|
| Total Nodes | 7 |
| Built | 5 |
| Unbuilt | 0 |
| Errored | 2 |
| Warnings | 1 |

## Dependency Graph

| Node | Runtime | Depth | Dependencies |
|------|---------|-------|-------------|
| mtcars | T | 0 |  |
| r_model | R | 1 | mtcars |
| py_stats | Python | 1 | mtcars |
| errored_mtcars | T | 1 | mtcars |
| errored_mtcars_r | R | 1 | mtcars |
| filtered_mtcars | T | 1 | mtcars |
| mtcars_mpg | T | 2 | filtered_mtcars |

## Built Nodes (5)

| Name | Runtime | Depth | Status |
|------|---------|-------|--------|
| mtcars | T | 0 | Completed |
| r_model | R | 1 | Completed |
| py_stats | Python | 1 | Completed |
| filtered_mtcars | T | 1 | Completed |
| mtcars_mpg | T | 2 | Completed |

## Unbuilt Nodes (0)

_All nodes have been built._

## Errored Nodes (2)

| Name | Error |
|------|-------|
| errored_mtcars | KeyError: Key `am_wrong` not found in Dict. |
| errored_mtcars_r | RuntimeError: [1m[33mError[39m in `dplyr::filter()`:[22m [1m[22m[36mi[39m In argument: `am_w... |

## Nodes with Warnings (1)

| Name | Warning |
|------|---------|
| filtered_mtcars | Warning flagged in build log. |


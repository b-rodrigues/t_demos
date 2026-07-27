# Pipeline Report


## Overview

| Metric | Count |
|--------|-------|
| Total Nodes | 7 |
| Built | 0 |
| Unbuilt | 7 |
| Errored | 0 |
| Warnings | 0 |

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

## Built Nodes (0)

_No nodes built yet._

## Unbuilt Nodes (7)

| Name | Runtime | Depth |
|------|---------|-------|
| mtcars | T | 0 |
| r_model | R | 1 |
| py_stats | Python | 1 |
| errored_mtcars | T | 1 |
| errored_mtcars_r | R | 1 |
| filtered_mtcars | T | 1 |
| mtcars_mpg | T | 2 |

## Errored Nodes (0)

_No errors._

## Nodes with Warnings (0)

_No warnings._


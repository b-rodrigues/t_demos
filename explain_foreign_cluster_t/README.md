# explain foreign_meta — Cluster Facts Demo

End-to-end validation of `explain(p.node).foreign_meta` clustering and
PCA facts after a real pipeline build. The pipeline builds seven
independent nodes:

- **`r_km`** (R) — `kmeans(mtcars, 3)`, seeded.
- **`r_hc`** (R) — `hclust(dist(mtcars))`, complete linkage.
- **`py_km`** (Python) — `KMeans`, 2 clusters.
- **`py_pca`** (Python) — `PCA`, 2 components.
- **`jl_km`** (Julia) — `Clustering.kmeans`, 2 clusters.
- **`jl_hc`** (Julia) — `Clustering.hclust`, complete linkage.
- **`jl_pca`** (Julia) — `MultivariateStats.fit(PCA)`, 2 components max.

After the build, a verify step loads the pipeline fresh via `t_make()` and
checks `task`, `n_clusters`, `method`, `n_components`, and variance
metrics through `check()`.

## What is tested

| Node | Checks |
|:---|:---|
| `r_km` | `task == "clustering"`, `n_clusters == 3`, `n_obs == 32`, `var_explained > 0.8` |
| `r_hc` | `method == "complete"`, `n_obs == 32` |
| `py_km` | `task == "clustering"`, `n_clusters == 2`, `inertia` present |
| `py_pca` | `task == "dim_reduction"`, `n_components == 2`, `var_first` present |
| `jl_km` | `task == "clustering"`, `n_clusters == 2`, `totalcost` present |
| `jl_hc` | `method == "complete"`, `n_obs == 3` |
| `jl_pca` | `task == "dim_reduction"`, `var_first` present |

## Why a demo instead of a unit test

The `meta` sidecar only exists after a real Nix build of R/Python nodes,
and `explain(p.node)` resolves it through build logs in a fresh process.
Unit tests cannot produce that state without a full build.

## Usage

```bash
t run src/pipeline.t
```

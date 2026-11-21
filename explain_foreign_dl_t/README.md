# explain_foreign_dl_t

End-to-end validation of `explain(p.node).foreign_meta` on deep learning, HuggingFace transformers, CatBoost, and Julia Flux, MCMCChains, SciML ODE, MultivariateStats, GaussianMixtures, ARCHModels, and XGBoost nodes.

## Run

```bash
t run src/pipeline.t
t run --failfast --unsafe src/verify_dl.t
```

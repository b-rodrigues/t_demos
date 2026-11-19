# explain_foreign_models_wave2_t

End-to-end validation of `explain(p.node).foreign_meta` for the wave 2 foreign model types:
- **R**: `mgcv::gam` (smooth model edf & metrics), `nlme::lme` / `gls` (linear mixed model groups & obs), `quantreg::rq` (quantile regression with tau), `urca::ur.df` (unit root test), `dist` (distance object), sparse `Matrix`.
- **Python**: `statsmodels.tsa.regime_switching.markov_regression.MarkovRegression` (Markov regime-switching model with regimes and time_series task).
- **Julia**: `CategoricalArray` (factor kind with levels), `MultivariateStats.MulticlassLDA` (multiclass LDA dimension reduction).

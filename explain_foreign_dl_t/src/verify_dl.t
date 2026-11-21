t_make()

-- Python torch Sequential & nested Module (total params = 58, leaf layers = 3)
check(explain(p.py_torch_seq).foreign_meta.kind == "model")
check(explain(p.py_torch_seq).foreign_meta.n_params == 58)
check(explain(p.py_torch_seq).foreign_meta.n_layers == 3)

check(explain(p.py_torch_nested).foreign_meta.kind == "model")
check(explain(p.py_torch_nested).foreign_meta.n_params == 58)
check(explain(p.py_torch_nested).foreign_meta.n_layers == 3)

check(explain(p.py_plain).foreign_meta.kind == "other")

-- Python Keras Sequential
check(explain(p.py_keras).foreign_meta.kind == "model")
check(explain(p.py_keras).foreign_meta.n_params == 58)
check(explain(p.py_keras).foreign_meta.n_layers == 2)
check(explain(p.py_keras).foreign_meta.method == "Adam")

-- Python HuggingFace transformers model
check(explain(p.py_hf_model).foreign_meta.kind == "model")
check(explain(p.py_hf_model).foreign_meta.method == "bert")
check(explain(p.py_hf_model).foreign_meta.n_params > 0)

-- Python CatBoost classifier
check(explain(p.py_catboost).foreign_meta.kind == "model")
check(explain(p.py_catboost).foreign_meta.task == "classification")
check(explain(p.py_catboost).foreign_meta.n_trees == 5)

-- Julia Flux via selective import
check(explain(p.jl_flux).foreign_meta.kind == "model")
check(explain(p.jl_flux).foreign_meta.n_layers == 2)
check(explain(p.jl_flux).foreign_meta.n_params == 58)

-- Julia MCMCChains.Chains
check(explain(p.jl_chains).foreign_meta.kind == "chain")
check(explain(p.jl_chains).foreign_meta.n_draws == 40)
check(explain(p.jl_chains).foreign_meta.n_params == 3)
check(explain(p.jl_chains).foreign_meta.n_chains == 2)

-- Julia SciMLBase ODEProblem
check(explain(p.jl_ode).foreign_meta.kind == "ode")
check(explain(p.jl_ode).foreign_meta.metrics.tspan_start == 0.0)
check(explain(p.jl_ode).foreign_meta.metrics.tspan_end == 2.5)

-- Julia MultivariateStats KernelPCA & ICA
check(explain(p.jl_kpca).foreign_meta.task == "dim_reduction")
check(explain(p.jl_kpca).foreign_meta.n_components >= 1)
check(explain(p.jl_kpca).foreign_meta.metrics.var_first > 0.0)
check(explain(p.jl_kpca).foreign_meta.metrics.var_first <= 1.0)
check(explain(p.jl_ica).foreign_meta.task == "dim_reduction")
check(explain(p.jl_ica).foreign_meta.n_components == 2)

-- Julia GaussianMixtures GMM, ARCHModels, XGBoost
check(explain(p.jl_gmm).foreign_meta.task == "density")
check(explain(p.jl_gmm).foreign_meta.n_components == 2)
check(explain(p.jl_arch).foreign_meta.task == "time_series")
check(explain(p.jl_xgb).foreign_meta.kind == "model")

print("+ foreign DL & ecosystem metadata: ok")

t_make()

check(explain(p.r_gam).foreign_meta.kind == "model")
check(explain(p.r_gam).foreign_meta.task == "regression")
check(explain(p.r_gam).foreign_meta.target == "mpg")
check(explain(p.r_gam).foreign_meta.n_obs == 32)
check(type(explain(p.r_gam).foreign_meta.metrics.edf) == "Float")
check(type(explain(p.r_gam).foreign_meta.metrics.r_squared) == "Float")

check(explain(p.r_lme).foreign_meta.kind == "model")
check(explain(p.r_lme).foreign_meta.task == "regression")
check(explain(p.r_lme).foreign_meta.n_obs == 108)
check(explain(p.r_lme).foreign_meta.groups.Subject == 27)

check(explain(p.r_rq).foreign_meta.kind == "model")
check(explain(p.r_rq).foreign_meta.task == "regression")
check(explain(p.r_rq).foreign_meta.metrics.tau == 0.5)

check(explain(p.r_urca).foreign_meta.kind == "test")
check(type(explain(p.r_urca).foreign_meta.metrics.statistic) == "Float")

check(explain(p.r_dist).foreign_meta.kind == "dist")
check(explain(p.r_dist).foreign_meta.n_obs == 5)
check(explain(p.r_dist).foreign_meta.method == "euclidean")

check(explain(p.r_sparse).foreign_meta.kind == "matrix")
check(explain(p.r_sparse).foreign_meta.metrics.nnz == 2)

check(explain(p.py_markov).foreign_meta.kind == "model")
check(explain(p.py_markov).foreign_meta.task == "time_series")
check(explain(p.py_markov).foreign_meta.metrics.n_regimes == 2)

check(explain(p.jl_factor).foreign_meta.kind == "factor")
check(explain(p.jl_factor).foreign_meta.n_obs == 5)
check(explain(p.jl_factor).foreign_meta.n_levels == 3)

check(explain(p.jl_mlda).foreign_meta.kind == "model")
check(explain(p.jl_mlda).foreign_meta.task == "dim_reduction")
check(explain(p.jl_mlda).foreign_meta.n_components == 1)
check(explain(p.jl_mlda).foreign_meta.metrics.n_classes == 2)

print("+ foreign wave 2 model metadata: ok")

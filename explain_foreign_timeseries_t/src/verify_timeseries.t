t_make()

-- Basic ARIMA models
check(explain(p.r_arima).foreign_meta.kind == "model")
check(explain(p.r_arima).foreign_meta.task == "time_series")
check(length(explain(p.r_arima).foreign_meta.order) == 3)
check(get(explain(p.r_arima).foreign_meta.order, 0) == 1)
check(length(explain(p.r_arima).foreign_meta.seasonal_order) == 4)
check(explain(p.r_arima).foreign_meta.n_obs > 100)
check(type(explain(p.r_arima).foreign_meta.metrics.loglik) == "Float")

check(explain(p.py_arima).foreign_meta.kind == "model")
check(explain(p.py_arima).foreign_meta.task == "time_series")
check(length(explain(p.py_arima).foreign_meta.order) == 3)
check(get(explain(p.py_arima).foreign_meta.order, 0) == 1)
check(explain(p.py_arima).foreign_meta.n_obs == 24)
check(type(explain(p.py_arima).foreign_meta.metrics.aic) == "Float")

check(explain(p.r_hw).foreign_meta.task == "time_series")
check(type(explain(p.r_hw).foreign_meta.metrics.alpha) == "Float")
check(type(explain(p.r_hw).foreign_meta.metrics.sse) == "Float")

check(explain(p.jl_sarima).foreign_meta.task == "time_series")
check(get(explain(p.jl_sarima).foreign_meta.order, 0) == 1)
check(type(explain(p.jl_sarima).foreign_meta.metrics.loglik) == "Float")

check(explain(p.r_ts).foreign_meta.kind == "series")
check(explain(p.r_ts).foreign_meta.n_obs == 144)

check(explain(p.r_stl).foreign_meta.task == "time_series")
check(explain(p.r_stl).foreign_meta.n_obs == 144)
check(type(explain(p.r_stl).foreign_meta.metrics.period) == "Int")

-- Forecast package & time series extensions
check(explain(p.r_ets).foreign_meta.kind == "model")
check(explain(p.r_ets).foreign_meta.task == "time_series")
check(type(explain(p.r_ets).foreign_meta.method) == "String")
check(type(explain(p.r_ets).foreign_meta.metrics.aic) == "Float")

check(explain(p.r_forecast).foreign_meta.kind == "forecast")
check(explain(p.r_forecast).foreign_meta.horizon == 12)

check(explain(p.r_tbats).foreign_meta.kind == "model")
check(explain(p.r_tbats).foreign_meta.task == "time_series")
check(type(explain(p.r_tbats).foreign_meta.metrics.aic) == "Float")

check(explain(p.r_zoo).foreign_meta.kind == "series")
check(explain(p.r_zoo).foreign_meta.n_obs == 24)

check(explain(p.py_var).foreign_meta.kind == "model")
check(explain(p.py_var).foreign_meta.task == "time_series")

print("+ foreign time-series metadata: ok")

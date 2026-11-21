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

-- Multivariate zoo (NROW = 10, not length = 20)
check(explain(p.r_zoo_mv).foreign_meta.kind == "series")
check(explain(p.r_zoo_mv).foreign_meta.n_obs == 10)
check(explain(p.r_zoo_mv).foreign_meta.n_features == 2)

-- auto.arima(AirPassengers)
check(explain(p.r_auto_arima).foreign_meta.kind == "model")
check(explain(p.r_auto_arima).foreign_meta.task == "time_series")
check(get(explain(p.r_auto_arima).foreign_meta.order, 0) == 2)
check(get(explain(p.r_auto_arima).foreign_meta.order, 1) == 1)
check(get(explain(p.r_auto_arima).foreign_meta.order, 2) == 1)
check(type(explain(p.r_auto_arima).foreign_meta.metrics.aic) == "Float")

-- nnetar & fractional tbats
check(explain(p.r_nnetar).foreign_meta.kind == "model")
check(explain(p.r_nnetar).foreign_meta.task == "time_series")
check(explain(p.r_tbats_frac).foreign_meta.kind == "model")
check(get(explain(p.r_tbats_frac).foreign_meta.seasonal_period, 1) == 365.25)

-- rugarch (unattached namespace -> rugarch::likelihood)
check(explain(p.r_ugarch).foreign_meta.kind == "model")
check(explain(p.r_ugarch).foreign_meta.task == "time_series")
check(explain(p.r_ugarch).foreign_meta.n_params > 0)
check(type(explain(p.r_ugarch).foreign_meta.metrics.loglik) == "Float")
check(type(explain(p.r_ugarch).foreign_meta.metrics.aic) == "Float")

-- tidyverts mable & multi-key/multi-model fable (horizon == 4, not nrow == 16)
check(explain(p.r_mable).foreign_meta.kind == "model")
check(explain(p.r_mable).foreign_meta.task == "time_series")
check(explain(p.r_mable).foreign_meta.n_features == 2)
check(explain(p.r_fable).foreign_meta.kind == "forecast")
check(explain(p.r_fable).foreign_meta.horizon == 4)

-- smooth, dlm, vars
check(explain(p.r_smooth).foreign_meta.kind == "model")
check(explain(p.r_smooth).foreign_meta.task == "time_series")
check(explain(p.r_dlm).foreign_meta.kind == "model")
check(explain(p.r_dlm).foreign_meta.n_obs == 144)
check(explain(p.r_vars).foreign_meta.kind == "model")
check(explain(p.r_vars).foreign_meta.n_equations == 2)
check(get(explain(p.r_vars).foreign_meta.order, 0) == 2)

-- Python pmdarima & tbats
check(explain(p.py_pmdarima).foreign_meta.kind == "model")
check(explain(p.py_pmdarima).foreign_meta.task == "time_series")
check(length(explain(p.py_pmdarima).foreign_meta.order) == 3)
check(type(explain(p.py_pmdarima).foreign_meta.metrics.aic) == "Float")
check(explain(p.py_tbats).foreign_meta.kind == "model")
check(get(explain(p.py_tbats).foreign_meta.seasonal_period, 1) == 14.5)

print("+ foreign time-series metadata: ok")

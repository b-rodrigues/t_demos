-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on time-series model nodes from R and Python.
--
-- Each model result carries a build-time `meta` sidecar with order facts
-- ([p, d, q], seasonal [P, D, Q, m]) and fit metrics (loglik, aic, bic).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R seasonal ARIMA on AirPassengers
    r_arima = node(
        command = <{ arima(AirPassengers, order = c(1, 1, 1), seasonal = list(order = c(1, 1, 1))) }>,
        runtime = R
    )

    -- statsmodels ARIMA(1, 0, 0) on 24 points
    py_arima = node(
        command = <{
            from statsmodels.tsa.arima.model import ARIMA
            y = [112.0, 118.0, 132.0, 129.0, 121.0, 135.0, 148.0, 136.0, 119.0, 104.0, 118.0, 115.0,
                 126.0, 141.0, 135.0, 125.0, 149.0, 170.0, 170.0, 158.0, 133.0, 114.0, 140.0, 145.0]
            ARIMA(y, order = (1, 0, 0)).fit()
        }>,
        runtime = Python
    )

    -- R Holt-Winters on AirPassengers
    r_hw = node(
        command = <{ HoltWinters(AirPassengers) }>,
        runtime = R
    )

    -- R time series object (AirPassengers, monthly)
    r_ts = node(
        command = <{ AirPassengers }>,
        runtime = R
    )

    -- R STL decomposition (seasonal/trend/remainder)
    r_stl = node(
        command = <{ stl(AirPassengers, s.window = "periodic") }>,
        runtime = R
    )

    -- StateSpaceModels.jl seasonal ARIMA
    jl_sarima = node(
        command = <{
            using StateSpaceModels
            y_ssm = [112.0, 118.0, 132.0, 129.0, 121.0, 135.0, 148.0, 136.0, 119.0, 104.0, 118.0, 115.0, 126.0, 141.0, 135.0, 125.0, 149.0, 170.0, 158.0, 133.0, 114.0, 140.0, 145.0, 125.0]
            m_ssm = SARIMA(y_ssm, order = (1, 1, 1), seasonal_order = (1, 1, 1, 12))
            fit!(m_ssm)
            m_ssm
        }>,
        runtime = Julia
    )

    -- R forecast::ets exponential smoothing state space model
    r_ets = node(
        command = <{
            library(forecast)
            ets(AirPassengers)
        }>,
        runtime = R
    )

    -- R forecast(...) output (new forecast kind with horizon)
    r_forecast = node(
        command = <{
            library(forecast)
            m = ets(AirPassengers)
            forecast(m, h = 12)
        }>,
        runtime = R
    )

    -- R forecast::tbats multi-seasonal model
    r_tbats = node(
        command = <{
            library(forecast)
            tbats(AirPassengers)
        }>,
        runtime = R
    )

    -- R zoo series object
    r_zoo = node(
        command = <{
            library(zoo)
            zoo(1:24, as.Date("2020-01-01") + 0:23)
        }>,
        runtime = R
    )

    -- statsmodels vector autoregression (VAR)
    py_var = node(
        command = <{
            import numpy as np
            import pandas as pd
            from statsmodels.tsa.api import VAR
            rng = np.random.default_rng(42)
            df_var = pd.DataFrame(rng.normal(size = (50, 2)), columns = ["a", "b"])
            VAR(df_var).fit(maxlags = 2)
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta Time-Series Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta time-series facts.")

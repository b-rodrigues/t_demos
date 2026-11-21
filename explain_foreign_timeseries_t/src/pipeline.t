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

    -- R multivariate zoo series (verifies NROW instead of length)
    r_zoo_mv = node(
        command = <{
            library(zoo)
            m <- matrix(1:20, ncol = 2)
            colnames(m) <- c("s1", "s2")
            zoo(m, as.Date("2020-01-01") + 0:9)
        }>,
        runtime = R
    )

    -- R forecast::auto.arima on AirPassengers (verifies ARIMA(2,1,1)(0,1,0)[12])
    r_auto_arima = node(
        command = <{
            library(forecast)
            auto.arima(AirPassengers)
        }>,
        runtime = R
    )

    -- R forecast::nnetar neural network autoregression
    r_nnetar = node(
        command = <{
            library(forecast)
            set.seed(1)
            nnetar(AirPassengers)
        }>,
        runtime = R
    )

    -- R forecast::tbats with fractional seasonal period (365.25)
    r_tbats_frac = node(
        command = <{
            library(forecast)
            y <- msts(sin(seq_len(800) / 10) + 0.1 * cos(seq_len(800)), seasonal.periods = c(7, 365.25))
            tbats(y)
        }>,
        runtime = R
    )

    -- R rugarch uGARCHfit (unattached rugarch:: namespace test for rugarch::likelihood)
    r_ugarch = node(
        command = <{
            set.seed(1)
            spec <- rugarch::ugarchspec()
            rugarch::ugarchfit(spec, rnorm(200))
        }>,
        runtime = R
    )

    -- R tidyverts mable (mdl_df) and multi-key/multi-model fable (16 rows, horizon = 4)
    r_mable = node(
        command = <{
            tsb <- tsibble::tsibble(
                id = rep(c("A", "B"), each = 24),
                t = rep(1:24, 2),
                y = c(sin(1:24) + 10, cos(1:24) + 20),
                key = id,
                index = t
            )
            fabletools::model(tsb, ets = fable::ETS(y), arima = fable::ARIMA(y))
        }>,
        runtime = R
    )

    r_fable = node(
        command = <{
            fabletools::forecast(r_mable, h = 4)
        }>,
        runtime = R
    )

    -- R smooth::es exponential smoothing
    r_smooth = node(
        command = <{
            smooth::es(AirPassengers)
        }>,
        runtime = R
    )

    -- R dlm::dlmFilter
    r_dlm = node(
        command = <{
            dlm::dlmFilter(as.numeric(AirPassengers), dlm::dlmModPoly(1))
        }>,
        runtime = R
    )

    -- R vars::VAR
    r_vars = node(
        command = <{
            set.seed(1)
            vars::VAR(data.frame(a = rnorm(40), b = rnorm(40)), p = 2)
        }>,
        runtime = R
    )

    -- Python pmdarima auto_arima
    py_pmdarima = node(
        command = <{
            import numpy as np
            import pmdarima as pm
            y = np.sin(np.arange(40) / 3.0) + np.arange(40) * 0.1
            pm.auto_arima(y, seasonal = False)
        }>,
        runtime = Python
    )

    -- Python tbats with fractional seasonal period
    py_tbats = node(
        command = <{
            import numpy as np
            from tbats import TBATS
            y = np.sin(np.arange(100) / 3.0) + 10.0
            TBATS(seasonal_periods = [7, 14.5], use_box_cox = False, use_arma_errors = False).fit(y)
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

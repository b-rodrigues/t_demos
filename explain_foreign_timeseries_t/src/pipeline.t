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
}

print("===============================================")
print("explain().foreign_meta Time-Series Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta time-series facts.")

-- timestral_demo: Benchmarking Timestral (5M & 209M) against R ARIMA on US Inflation (CPI)

p = pipeline {
  -- 1. Read economic benchmark dataset
  raw_data = node(
    command = read_csv("data/cpi.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  -- 2. Tuned R SARIMA model via forecast::auto.arima (evaluates both seasonal SARIMA and non-seasonal ARIMA)
  r_arima = rn(
    command = <{
      library(forecast)
      train_cpi = head(raw_data$cpi, -12)
      ts_train = ts(train_cpi, frequency = 12)
      fit = auto.arima(ts_train, seasonal = TRUE)
      preds = as.numeric(forecast(fit, h = 12)$mean)
      data.frame(step = 1:12, arima = preds)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  -- 3. Python Timestral-5M model
  timestral_5m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

cpi_vals = raw_data["cpi"].values[:-12]
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")
res = fc.forecast(cpi_vals, prediction_length=12)
preds = res.median.cpu().numpy().squeeze().tolist()
timestral_5m = pd.DataFrame({"step": list(range(1, 13)), "timestral_5m": preds})
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  -- 4. Python Timestral-209M model
  timestral_209m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

cpi_vals = raw_data["cpi"].values[:-12]
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")
res = fc.forecast(cpi_vals, prediction_length=12)
preds = res.median.cpu().numpy().squeeze().tolist()
timestral_209m = pd.DataFrame({"step": list(range(1, 13)), "timestral_209m": preds})
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  -- 5. Benchmark Comparison Metrics (R node)
  benchmark_metrics = rn(
    command = <{
      actual = tail(raw_data$cpi, 12)
      rmse <- function(pred, act) sqrt(mean((pred - act)^2))
      mae  <- function(pred, act) mean(abs(pred - act))

      arima_rmse = rmse(r_arima$arima, actual)
      arima_mae  = mae(r_arima$arima, actual)

      t5m_rmse   = rmse(timestral_5m$timestral_5m, actual)
      t5m_mae    = mae(timestral_5m$timestral_5m, actual)

      t209m_rmse = rmse(timestral_209m$timestral_209m, actual)
      t209m_mae  = mae(timestral_209m$timestral_209m, actual)

      benchmark_metrics = data.frame(
        model = c("R Tuned SARIMA", "Timestral-5M", "Timestral-209M"),
        rmse  = c(arima_rmse, t5m_rmse, t209m_rmse),
        mae   = c(arima_mae, t5m_mae, t209m_mae)
      )
      print(benchmark_metrics)
      benchmark_metrics
    }>,
    deserializer = [
      raw_data: ^csv,
      r_arima: ^csv,
      timestral_5m: ^csv,
      timestral_209m: ^csv
    ],
    serializer = ^csv
  )
}

-- Materialize and build
populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- Guard against failed pipeline node execution (Rule 5)
if (is_error(p.raw_data)) {
  error(str_join(["Node 'raw_data' errored: ", error_msg(p.raw_data)]))
}
if (is_error(p.r_arima)) {
  error(str_join(["Node 'r_arima' errored: ", error_msg(p.r_arima)]))
}
if (is_error(p.timestral_5m)) {
  error(str_join(["Node 'timestral_5m' errored: ", error_msg(p.timestral_5m)]))
}
if (is_error(p.timestral_209m)) {
  error(str_join(["Node 'timestral_209m' errored: ", error_msg(p.timestral_209m)]))
}
if (is_error(p.benchmark_metrics)) {
  error(str_join(["Node 'benchmark_metrics' errored: ", error_msg(p.benchmark_metrics)]))
}

-- Assertions with built-in check() (Rule 5)
check(expect_nodes(p, ["raw_data", "r_arima", "timestral_5m", "timestral_209m", "benchmark_metrics"]))

metrics_res = read_node(p.benchmark_metrics)
check(expect_nrow(metrics_res, 3))

print("✓ timestral_demo: all assertions passed successfully!")

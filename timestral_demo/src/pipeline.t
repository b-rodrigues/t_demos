-- timestral_demo: Multi-Study Benchmark of Timestral (5M & 209M) vs State-of-the-Art Econometrics (ARIMA, ETS, MinT, VAR, ARIMAX)

p = pipeline {
  ----------------------------------------------------------------------------
  -- STUDY 1: Canonical Inflation Benchmark (CPIAUCSL)
  ----------------------------------------------------------------------------
  raw_data = node(
    command = read_csv("data/cpi.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  r_arima = rn(
    command = <{
      library(forecast)
      train_cpi = head(raw_data$cpi, -12)
      ts_train  = ts(train_cpi, frequency = 12)

      # 1. Best ARIMA
      fit_arima = auto.arima(ts_train, seasonal = TRUE)
      fc_arima  = as.numeric(forecast(fit_arima, h = 12)$mean)

      # 2. State-Space Exponential Smoothing (ETS)
      fit_ets   = ets(ts_train)
      fc_ets    = as.numeric(forecast(fit_ets, h = 12)$mean)

      # 3. Hybrid Ensemble (ARIMA + ETS) / 2
      fc_ens    = (fc_arima + fc_ets) / 2

      data.frame(
        step     = 1:12,
        arima    = fc_arima,
        ets      = fc_ets,
        ensemble = fc_ens
      )
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

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

  benchmark_metrics = rn(
    command = <{
      actual = tail(raw_data$cpi, 12)
      rmse <- function(pred, act) sqrt(mean((pred - act)^2))
      mae  <- function(pred, act) mean(abs(pred - act))

      arima_rmse = rmse(r_arima$arima, actual)
      arima_mae  = mae(r_arima$arima, actual)

      ets_rmse   = rmse(r_arima$ets, actual)
      ets_mae    = mae(r_arima$ets, actual)

      ens_rmse   = rmse(r_arima$ensemble, actual)
      ens_mae    = mae(r_arima$ensemble, actual)

      t5m_rmse   = rmse(timestral_5m$timestral_5m, actual)
      t5m_mae    = mae(timestral_5m$timestral_5m, actual)

      t209m_rmse = rmse(timestral_209m$timestral_209m, actual)
      t209m_mae  = mae(timestral_209m$timestral_209m, actual)

      benchmark_metrics = data.frame(
        model = c("R ARIMA (0, 2, 2)", "R ETS (State-Space)", "R Ensemble (ARIMA+ETS)", "Timestral-5M", "Timestral-209M"),
        rmse  = round(c(arima_rmse, ets_rmse, ens_rmse, t5m_rmse, t209m_rmse), 4),
        mae   = round(c(arima_mae, ets_mae, ens_mae, t5m_mae, t209m_mae), 4)
      )
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

  ----------------------------------------------------------------------------
  -- STUDY 2 (Proposition 1): Multi-Sector Retail Sales & MinT Reconciliation
  ----------------------------------------------------------------------------
  retail_raw_data = node(
    command = read_csv("data/retail_sales.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  retail_r_arima = rn(
    command = <{
      library(forecast)
      train = head(retail_raw_data, -12)

      # In Census Retail Trade, 5 sectors do not sum to total because remaining sectors
      # (gas stations, pharmacies, building materials, electronics) make up 'other_retail'.
      train$other = train$total - (train$automotive + train$food_beverage + train$clothing + train$ecommerce + train$general_merchandise)

      sectors_5 = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise")
      sectors_all = c("total", sectors_5, "other")

      res_arima = data.frame(step = 1:12)
      res_ets   = data.frame(step = 1:12)

      for (s in sectors_all) {
        ts_y = ts(train[[s]], frequency = 12)
        fit_a = auto.arima(ts_y)
        res_arima[[s]] = as.numeric(forecast(fit_a, h = 12)$mean)

        fit_e = ets(ts_y)
        res_ets[[s]]   = as.numeric(forecast(fit_e, h = 12)$mean)
      }

      # MinT (Minimum Trace) optimal hierarchical reconciliation:
      # S: summing matrix mapping 6 bottom components to Total + 6 components
      S = rbind(rep(1, 6), diag(6))
      P = solve(t(S) %*% S) %*% t(S)

      base_mat = as.matrix(res_ets[, sectors_all])
      reconciled = t(S %*% P %*% t(base_mat))
      colnames(reconciled) = sectors_all

      res = data.frame(step = 1:12)
      for (s in c("total", sectors_5)) {
        res[[paste0("arima_", s)]] = res_arima[[s]]
        res[[paste0("ets_", s)]]   = res_ets[[s]]
        res[[paste0("mint_", s)]]  = reconciled[, s]
      }

      retail_r_arima = res
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  retail_timestral_5m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

train = retail_raw_data.iloc[:-12]
sectors = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise"]
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

res = {"step": list(range(1, 13))}
for s in sectors:
    vals = train[s].values
    res[f"t5m_{s}"] = fc.forecast(vals, prediction_length=12).median.cpu().numpy().squeeze().tolist()

res_df = pd.DataFrame(res)
res_df["t5m_bottom_up"] = (res_df["t5m_automotive"] + res_df["t5m_food_beverage"] +
                           res_df["t5m_clothing"] + res_df["t5m_ecommerce"] + res_df["t5m_general_merchandise"])
retail_timestral_5m = res_df
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  retail_timestral_209m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

train = retail_raw_data.iloc[:-12]
sectors = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise"]
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

res = {"step": list(range(1, 13))}
for s in sectors:
    vals = train[s].values
    res[f"t209m_{s}"] = fc.forecast(vals, prediction_length=12).median.cpu().numpy().squeeze().tolist()

res_df = pd.DataFrame(res)
res_df["t209m_bottom_up"] = (res_df["t209m_automotive"] + res_df["t209m_food_beverage"] +
                             res_df["t209m_clothing"] + res_df["t209m_ecommerce"] + res_df["t209m_general_merchandise"])
retail_timestral_209m = res_df
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  retail_benchmark_metrics = rn(
    command = <{
      actual = tail(retail_raw_data, 12)
      sectors = c("total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise")
      rmse <- function(pred, act) sqrt(mean((pred - act)^2))
      mae  <- function(pred, act) mean(abs(pred - act))

      rows <- list()
      for (s in sectors) {
        act = actual[[s]]
        a_p    = retail_r_arima[[paste0("arima_", s)]]
        e_p    = retail_r_arima[[paste0("ets_", s)]]
        m_p    = retail_r_arima[[paste0("mint_", s)]]
        t5_p   = retail_timestral_5m[[paste0("t5m_", s)]]
        t209_p = retail_timestral_209m[[paste0("t209m_", s)]]

        rows[[s]] = data.frame(
          sector      = s,
          arima_rmse  = round(rmse(a_p, act), 1),
          ets_rmse    = round(rmse(e_p, act), 1),
          mint_rmse   = round(rmse(m_p, act), 1),
          t5m_rmse    = round(rmse(t5_p, act), 1),
          t209m_rmse  = round(rmse(t209_p, act), 1),
          mint_mae    = round(mae(m_p, act), 1),
          t5m_mae     = round(mae(t5_p, act), 1),
          t209m_mae   = round(mae(t209_p, act), 1)
        )
      }
      retail_benchmark_metrics = do.call(rbind, rows)
      rownames(retail_benchmark_metrics) <- NULL
      retail_benchmark_metrics
    }>,
    deserializer = [
      retail_raw_data: ^csv,
      retail_r_arima: ^csv,
      retail_timestral_5m: ^csv,
      retail_timestral_209m: ^csv
    ],
    serializer = ^csv
  )

  ----------------------------------------------------------------------------
  -- STUDY 3 (Proposition 3): Macro Triad & Policy Rate (VAR, ARIMAX & Covariates)
  ----------------------------------------------------------------------------
  macro_raw_data = node(
    command = read_csv("data/macro_triad.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  macro_r_models = rn(
    command = <{
      library(forecast)
      library(vars)
      train = head(macro_raw_data, -12)
      test  = tail(macro_raw_data, 12)

      # 1. VAR with AIC-selected optimal lag (p = 6)
      ts_train = ts(train[, c("cpi", "unrate", "fedfunds")], frequency = 12)
      fit_var = VAR(ts_train, p = 6, type = "both")
      pred_var = predict(fit_var, n.ahead = 12)$fcst

      # 2. ARIMAX on CPI with FEDFUNDS as exogenous regressor
      fit_cpi_arimax = auto.arima(ts(train$cpi, frequency = 12), xreg = train$fedfunds)
      fc_cpi_arimax = forecast(fit_cpi_arimax, xreg = test$fedfunds, h = 12)

      # 3. ARIMAX on UNRATE with FEDFUNDS as exogenous regressor
      fit_unrate_arimax = auto.arima(ts(train$unrate, frequency = 12), xreg = train$fedfunds)
      fc_unrate_arimax = forecast(fit_unrate_arimax, xreg = test$fedfunds, h = 12)

      macro_r_models = data.frame(
        step          = 1:12,
        var_cpi       = as.numeric(pred_var$cpi[, "fcst"]),
        var_unrate    = as.numeric(pred_var$unrate[, "fcst"]),
        arimax_cpi    = as.numeric(fc_cpi_arimax$mean),
        arimax_unrate = as.numeric(fc_unrate_arimax$mean)
      )
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  macro_timestral_5m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

train = macro_raw_data.iloc[:-12]
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

# 1. Pure univariate forecasts
cpi_univ = fc.forecast(train["cpi"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()
unrate_univ = fc.forecast(train["unrate"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()

# 2. Conditioned forecasts with known_covariates (FEDFUNDS over context + horizon)
ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :]
cpi_cov = fc.forecast(train["cpi"].values, prediction_length=12, known_covariates=ff_known).median.cpu().numpy().squeeze().tolist()
unrate_cov = fc.forecast(train["unrate"].values, prediction_length=12, known_covariates=ff_known).median.cpu().numpy().squeeze().tolist()

macro_timestral_5m = pd.DataFrame({
  "step": list(range(1, 13)),
  "t5m_cpi_univ": cpi_univ,
  "t5m_cpi_cov": cpi_cov,
  "t5m_unrate_univ": unrate_univ,
  "t5m_unrate_cov": unrate_cov
})
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  macro_timestral_209m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

train = macro_raw_data.iloc[:-12]
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

# 1. Pure univariate forecasts
cpi_univ = fc.forecast(train["cpi"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()
unrate_univ = fc.forecast(train["unrate"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()

# 2. Conditioned forecasts with known_covariates (FEDFUNDS over context + horizon)
ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :]
cpi_cov = fc.forecast(train["cpi"].values, prediction_length=12, known_covariates=ff_known).median.cpu().numpy().squeeze().tolist()
unrate_cov = fc.forecast(train["unrate"].values, prediction_length=12, known_covariates=ff_known).median.cpu().numpy().squeeze().tolist()

macro_timestral_209m = pd.DataFrame({
  "step": list(range(1, 13)),
  "t209m_cpi_univ": cpi_univ,
  "t209m_cpi_cov": cpi_cov,
  "t209m_unrate_univ": unrate_univ,
  "t209m_unrate_cov": unrate_cov
})
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  macro_benchmark_metrics = rn(
    command = <{
      actual = tail(macro_raw_data, 12)
      rmse <- function(pred, act) sqrt(mean((pred - act)^2))
      mae  <- function(pred, act) mean(abs(pred - act))

      macro_benchmark_metrics = data.frame(
        target = c(rep("CPI (Inflation)", 6), rep("UNRATE (Chômage)", 6)),
        model  = c(
          "VAR(6) Multivarié (AIC optimal)",
          "ARIMAX (avec FedFunds)",
          "Timestral-5M (Univarié)",
          "Timestral-5M (avec FedFunds exogène)",
          "Timestral-209M (Univarié)",
          "Timestral-209M (avec FedFunds exogène)",
          "VAR(6) Multivarié (AIC optimal)",
          "ARIMAX (avec FedFunds)",
          "Timestral-5M (Univarié)",
          "Timestral-5M (avec FedFunds exogène)",
          "Timestral-209M (Univarié)",
          "Timestral-209M (avec FedFunds exogène)"
        ),
        rmse   = round(c(
          rmse(macro_r_models$var_cpi, actual$cpi),
          rmse(macro_r_models$arimax_cpi, actual$cpi),
          rmse(macro_timestral_5m$t5m_cpi_univ, actual$cpi),
          rmse(macro_timestral_5m$t5m_cpi_cov, actual$cpi),
          rmse(macro_timestral_209m$t209m_cpi_univ, actual$cpi),
          rmse(macro_timestral_209m$t209m_cpi_cov, actual$cpi),
          rmse(macro_r_models$var_unrate, actual$unrate),
          rmse(macro_r_models$arimax_unrate, actual$unrate),
          rmse(macro_timestral_5m$t5m_unrate_univ, actual$unrate),
          rmse(macro_timestral_5m$t5m_unrate_cov, actual$unrate),
          rmse(macro_timestral_209m$t209m_unrate_univ, actual$unrate),
          rmse(macro_timestral_209m$t209m_unrate_cov, actual$unrate)
        ), 3),
        mae    = round(c(
          mae(macro_r_models$var_cpi, actual$cpi),
          mae(macro_r_models$arimax_cpi, actual$cpi),
          mae(macro_timestral_5m$t5m_cpi_univ, actual$cpi),
          mae(macro_timestral_5m$t5m_cpi_cov, actual$cpi),
          mae(macro_timestral_209m$t209m_cpi_univ, actual$cpi),
          mae(macro_timestral_209m$t209m_cpi_cov, actual$cpi),
          mae(macro_r_models$var_unrate, actual$unrate),
          mae(macro_r_models$arimax_unrate, actual$unrate),
          mae(macro_timestral_5m$t5m_unrate_univ, actual$unrate),
          mae(macro_timestral_5m$t5m_unrate_cov, actual$unrate),
          mae(macro_timestral_209m$t209m_unrate_univ, actual$unrate),
          mae(macro_timestral_209m$t209m_unrate_cov, actual$unrate)
        ), 3)
      )
      macro_benchmark_metrics
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      macro_r_models: ^csv,
      macro_timestral_5m: ^csv,
      macro_timestral_209m: ^csv
    ],
    serializer = ^csv
  )

  ----------------------------------------------------------------------------
  -- STUDY 4: Comprehensive Quarto Report in French
  ----------------------------------------------------------------------------
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize and build
populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- Guard against failed pipeline node execution (Rule 5)
nodes_to_guard = [
  "raw_data", "r_arima", "timestral_5m", "timestral_209m", "benchmark_metrics",
  "retail_raw_data", "retail_r_arima", "retail_timestral_5m", "retail_timestral_209m", "retail_benchmark_metrics",
  "macro_raw_data", "macro_r_models", "macro_timestral_5m", "macro_timestral_209m", "macro_benchmark_metrics",
  "report"
]

if (is_error(p.raw_data)) { error(str_join(["Node 'raw_data' errored: ", error_msg(p.raw_data)])) }
if (is_error(p.r_arima)) { error(str_join(["Node 'r_arima' errored: ", error_msg(p.r_arima)])) }
if (is_error(p.timestral_5m)) { error(str_join(["Node 'timestral_5m' errored: ", error_msg(p.timestral_5m)])) }
if (is_error(p.timestral_209m)) { error(str_join(["Node 'timestral_209m' errored: ", error_msg(p.timestral_209m)])) }
if (is_error(p.benchmark_metrics)) { error(str_join(["Node 'benchmark_metrics' errored: ", error_msg(p.benchmark_metrics)])) }
if (is_error(p.retail_raw_data)) { error(str_join(["Node 'retail_raw_data' errored: ", error_msg(p.retail_raw_data)])) }
if (is_error(p.retail_r_arima)) { error(str_join(["Node 'retail_r_arima' errored: ", error_msg(p.retail_r_arima)])) }
if (is_error(p.retail_timestral_5m)) { error(str_join(["Node 'retail_timestral_5m' errored: ", error_msg(p.retail_timestral_5m)])) }
if (is_error(p.retail_timestral_209m)) { error(str_join(["Node 'retail_timestral_209m' errored: ", error_msg(p.retail_timestral_209m)])) }
if (is_error(p.retail_benchmark_metrics)) { error(str_join(["Node 'retail_benchmark_metrics' errored: ", error_msg(p.retail_benchmark_metrics)])) }
if (is_error(p.macro_raw_data)) { error(str_join(["Node 'macro_raw_data' errored: ", error_msg(p.macro_raw_data)])) }
if (is_error(p.macro_r_models)) { error(str_join(["Node 'macro_r_models' errored: ", error_msg(p.macro_r_models)])) }
if (is_error(p.macro_timestral_5m)) { error(str_join(["Node 'macro_timestral_5m' errored: ", error_msg(p.macro_timestral_5m)])) }
if (is_error(p.macro_timestral_209m)) { error(str_join(["Node 'macro_timestral_209m' errored: ", error_msg(p.macro_timestral_209m)])) }
if (is_error(p.macro_benchmark_metrics)) { error(str_join(["Node 'macro_benchmark_metrics' errored: ", error_msg(p.macro_benchmark_metrics)])) }
if (is_error(p.report)) { error(str_join(["Node 'report' errored: ", error_msg(p.report)])) }

-- Assertions with built-in check() (Rule 5)
check(expect_nodes(p, nodes_to_guard))

cpi_metrics = read_node(p.benchmark_metrics)
check(expect_nrow(cpi_metrics, 5))

retail_metrics = read_node(p.retail_benchmark_metrics)
check(expect_nrow(retail_metrics, 6))

macro_metrics = read_node(p.macro_benchmark_metrics)
check(expect_nrow(macro_metrics, 12))

print("✓ timestral_demo: all 16 advanced nodes and assertions passed successfully!")

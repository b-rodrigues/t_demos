-- timestral_demo: Multi-Study Benchmark of Timestral (5M & 209M) vs State-of-the-Art Econometrics (ARIMA, ETS, MinT, VAR, ARIMAX)

p = pipeline {
  ----------------------------------------------------------------------------
  -- STUDY 1: Canonical Inflation Benchmark (CPIAUCSL) & Probabilistic Evaluation
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
      test_cpi  = tail(raw_data$cpi, 12)
      ts_train  = ts(train_cpi, frequency = 12)
      last_val  = tail(train_cpi, 1)

      # 1. Naive & Drift baselines
      fc_naive = rep(last_val, 12)
      fit_rwf  = rwf(ts_train, h = 12, drift = TRUE)
      fc_drift = as.numeric(fit_rwf$mean)

      # 2. Dynamic ARIMA with extracted specification & predictive distribution
      fit_arima  = auto.arima(ts_train, seasonal = TRUE)
      fc_obj_ari = forecast(fit_arima, h = 12, level = c(80, 95))
      fc_arima   = as.numeric(fc_obj_ari$mean)
      sd_arima   = as.numeric((fc_obj_ari$upper[, "95%"] - fc_obj_ari$lower[, "95%"]) / (2 * qnorm(0.975)))
      arima_spec = paste0("ARIMA(", paste(arimaorder(fit_arima), collapse = ","), ")")

      # 3. State-Space Exponential Smoothing (ETS)
      fit_ets    = ets(ts_train)
      fc_obj_ets = forecast(fit_ets, h = 12, level = c(80, 95))
      fc_ets     = as.numeric(fc_obj_ets$mean)
      sd_ets     = as.numeric((fc_obj_ets$upper[, "95%"] - fc_obj_ets$lower[, "95%"]) / (2 * qnorm(0.975)))
      ets_spec   = fit_ets$method

      # 4. Hybrid Ensemble (ARIMA + ETS) / 2
      fc_ens     = (fc_arima + fc_ets) / 2

      data.frame(
        step       = 1:12,
        naive      = fc_naive,
        drift      = fc_drift,
        arima      = fc_arima,
        arima_sd   = sd_arima,
        arima_spec = rep(arima_spec, 12),
        ets        = fc_ets,
        ets_sd     = sd_ets,
        ets_spec   = rep(ets_spec, 12),
        ensemble   = fc_ens
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
q_mat = res.quantiles.cpu().numpy().squeeze()
q_levels = list(res.quantile_levels)

data_dict = {"step": list(range(1, 13)), "timestral_5m": preds}
for i, lvl in enumerate(q_levels):
    col_name = f"q_{int(round(lvl*100)):02d}"
    data_dict[col_name] = q_mat[:, i].tolist()

timestral_5m = pd.DataFrame(data_dict)
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
q_mat = res.quantiles.cpu().numpy().squeeze()
q_levels = list(res.quantile_levels)

data_dict = {"step": list(range(1, 13)), "timestral_209m": preds}
for i, lvl in enumerate(q_levels):
    col_name = f"q_{int(round(lvl*100)):02d}"
    data_dict[col_name] = q_mat[:, i].tolist()

timestral_209m = pd.DataFrame(data_dict)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  benchmark_metrics = rn(
    command = <{
      actual = tail(raw_data$cpi, 12)
      last_train = tail(head(raw_data$cpi, -12), 1)
      actual_inflation = (tail(actual, 1) - last_train) / last_train * 100

      rmse <- function(pred, act) sqrt(mean((pred - act)^2))
      mae  <- function(pred, act) mean(abs(pred - act))
      calc_inf <- function(pred) (tail(pred, 1) - last_train) / last_train * 100

      models_list = list(
        "Naive (Marche aléatoire)"  = r_arima$naive,
        "RW avec Dérive (Drift)"     = r_arima$drift,
        "R ARIMA (optimal)"          = r_arima$arima,
        "R ETS (Espace d'états)"    = r_arima$ets,
        "R Ensemble (ARIMA+ETS)"    = r_arima$ensemble,
        "Timestral-5M (Zero-shot)"   = timestral_5m$timestral_5m,
        "Timestral-209M (Zero-shot)" = timestral_209m$timestral_209m
      )

      naive_rmse = rmse(r_arima$naive, actual)

      rows = lapply(names(models_list), function(m) {
        p = models_list[[m]]
        m_rmse = rmse(p, actual)
        data.frame(
          model              = m,
          rmse               = round(m_rmse, 4),
          mae                = round(mae(p, actual), 4),
          relative_rmse      = round(m_rmse / naive_rmse, 3),
          implied_inflation  = round(calc_inf(p), 2)
        )
      })

      benchmark_metrics = do.call(rbind, rows)
      rownames(benchmark_metrics) <- NULL
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

  cpi_probabilistic_metrics = rn(
    command = <{
      actual = tail(raw_data$cpi, 12)
      q_levels = c(0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99)

      # Evaluate Pinball loss & prediction interval coverage
      eval_q_dist <- function(q_matrix) {
        # q_matrix is 12 x 21
        loss_mat = matrix(0, 12, length(q_levels))
        cov80 = logical(12)
        cov90 = logical(12)
        for (t in 1:12) {
          y = actual[t]
          q_row = q_matrix[t, ]
          loss_mat[t, ] = ifelse(y >= q_row, q_levels * (y - q_row), (1 - q_levels) * (q_row - y))
          cov80[t] = (y >= q_row[3]) && (y <= q_row[19])  # 0.10 to 0.90 (80% interval)
          cov90[t] = (y >= q_row[2]) && (y <= q_row[20])  # 0.05 to 0.95 (90% interval)
        }
        c(pinball = mean(loss_mat), cov80 = mean(cov80), cov90 = mean(cov90))
      }

      # 1. ARIMA Gaussian quantiles
      arima_q = matrix(0, 12, length(q_levels))
      for (t in 1:12) {
        arima_q[t, ] = r_arima$arima[t] + r_arima$arima_sd[t] * qnorm(q_levels)
      }
      res_arima = eval_q_dist(arima_q)

      # 2. ETS Gaussian quantiles
      ets_q = matrix(0, 12, length(q_levels))
      for (t in 1:12) {
        ets_q[t, ] = r_arima$ets[t] + r_arima$ets_sd[t] * qnorm(q_levels)
      }
      res_ets = eval_q_dist(ets_q)

      # 3. Timestral-5M native 21 quantiles
      q_cols = sprintf("q_%02d", round(q_levels * 100))
      t5m_q = as.matrix(timestral_5m[, q_cols])
      res_t5m = eval_q_dist(t5m_q)

      # 4. Timestral-209M native 21 quantiles
      t209m_q = as.matrix(timestral_209m[, q_cols])
      res_t209m = eval_q_dist(t209m_q)

      cpi_probabilistic_metrics = data.frame(
        model              = c("R ARIMA (Gaussien)", "R ETS (Gaussien)", "Timestral-5M (21 quantiles)", "Timestral-209M (21 quantiles)"),
        mean_pinball_loss  = round(c(res_arima["pinball"], res_ets["pinball"], res_t5m["pinball"], res_t209m["pinball"]), 4),
        coverage_80        = round(c(res_arima["cov80"], res_ets["cov80"], res_t5m["cov80"], res_t209m["cov80"]), 3),
        coverage_90        = round(c(res_arima["cov90"], res_ets["cov90"], res_t5m["cov90"], res_t209m["cov90"]), 3)
      )
      rownames(cpi_probabilistic_metrics) <- NULL
      cpi_probabilistic_metrics
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
  -- STUDY 2: Multi-Sector Retail Sales & Real MinT Reconciliation
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

      # Construct complete hierarchy: Census Retail total comprises 5 focal sectors
      # plus residual 'other' (building materials, pharmacies, gas stations, electronics)
      train$other = train$total - (train$automotive + train$food_beverage + train$clothing + train$ecommerce + train$general_merchandise)

      sectors_5      = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise")
      sectors_all    = c("total", sectors_5, "other")
      sectors_bottom = c(sectors_5, "other")

      # 1. Fit base models (ARIMA and ETS) and collect in-sample residuals
      fits_ets   = list()
      fits_arima = list()
      fcasts_ets = list()
      fcasts_ari = list()
      res_ets    = list()

      for (s in sectors_all) {
        y_ts = ts(train[[s]], frequency = 12)

        fit_e = ets(y_ts)
        fits_ets[[s]]   = fit_e
        fcasts_ets[[s]] = as.numeric(forecast(fit_e, h = 12)$mean)
        res_ets[[s]]    = as.numeric(residuals(fit_e))

        fit_a = auto.arima(y_ts)
        fits_arima[[s]] = fit_a
        fcasts_ari[[s]] = as.numeric(forecast(fit_a, h = 12)$mean)
      }

      # 2. Real MinT-shrink (Minimum Trace with Shrinkage Covariance) Reconciliation:
      # (Wickramasuriya et al., 2019; Schäfer & Strimmer, 2005)
      # P = (S' W^{-1} S)^{-1} S' W^{-1} where W is the shrinkage residual covariance matrix
      S = rbind(rep(1, 6), diag(6))
      rownames(S) = sectors_all
      colnames(S) = sectors_bottom

      res_mat  = do.call(cbind, res_ets)
      n_res    = nrow(res_mat)
      S_sample = cov(res_mat)
      tar      = diag(diag(S_sample))
      res_c    = scale(res_mat, center = TRUE, scale = FALSE)
      p_dim    = ncol(res_mat)
      var_cov  = matrix(0, p_dim, p_dim)
      for (i in 1:p_dim) {
        for (j in 1:p_dim) {
          if (i != j) {
            v = res_c[, i] * res_c[, j]
            var_cov[i, j] = (n_res / ((n_res - 1)^3)) * sum((v - mean(v))^2)
          }
        }
      }
      off_diag_sq = sum((S_sample - tar)^2)
      lambda = if (off_diag_sq > 0) sum(var_cov) / off_diag_sq else 0
      lambda = max(0, min(1, lambda))
      W_shrink = (1 - lambda) * S_sample + lambda * tar
      Wi = solve(W_shrink)

      P_mint = solve(t(S) %*% Wi %*% S) %*% t(S) %*% Wi

      base_mat = do.call(cbind, fcasts_ets)
      reconciled_mat = t(S %*% P_mint %*% t(base_mat))
      colnames(reconciled_mat) = sectors_all

      # Mathematical coherence validation: sum of bottom series must equal total
      coherence_err = max(abs(reconciled_mat[, "total"] - rowSums(reconciled_mat[, sectors_bottom])))

      res = data.frame(
        step = 1:12,
        mint_lambda = rep(lambda, 12),
        mint_coherence_max_error = rep(coherence_err, 12)
      )
      for (s in sectors_all) {
        res[[paste0("arima_", s)]] = fcasts_ari[[s]]
        res[[paste0("ets_", s)]]   = fcasts_ets[[s]]
        res[[paste0("mint_", s)]]  = reconciled_mat[, s]
        res[[paste0("naive_", s)]] = rep(tail(train[[s]], 1), 12)
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

train = retail_raw_data.iloc[:-12].copy()
train["other"] = train["total"] - (train["automotive"] + train["food_beverage"] + train["clothing"] + train["ecommerce"] + train["general_merchandise"])

sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

res = {"step": list(range(1, 13))}
for s in sectors_all:
    vals = train[s].values
    res[f"t5m_{s}"] = fc.forecast(vals, prediction_length=12).median.cpu().numpy().squeeze().tolist()

res_df = pd.DataFrame(res)
# Bottom-up sum of all 6 bottom series
res_df["t5m_bottom_up"] = (res_df["t5m_automotive"] + res_df["t5m_food_beverage"] +
                           res_df["t5m_clothing"] + res_df["t5m_ecommerce"] +
                           res_df["t5m_general_merchandise"] + res_df["t5m_other"])
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

train = retail_raw_data.iloc[:-12].copy()
train["other"] = train["total"] - (train["automotive"] + train["food_beverage"] + train["clothing"] + train["ecommerce"] + train["general_merchandise"])

sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

res = {"step": list(range(1, 13))}
for s in sectors_all:
    vals = train[s].values
    res[f"t209m_{s}"] = fc.forecast(vals, prediction_length=12).median.cpu().numpy().squeeze().tolist()

res_df = pd.DataFrame(res)
# Bottom-up sum of all 6 bottom series
res_df["t209m_bottom_up"] = (res_df["t209m_automotive"] + res_df["t209m_food_beverage"] +
                             res_df["t209m_clothing"] + res_df["t209m_ecommerce"] +
                             res_df["t209m_general_merchandise"] + res_df["t209m_other"])
retail_timestral_209m = res_df
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  retail_benchmark_metrics = rn(
    command = <{
      actual = tail(retail_raw_data, 12)
      actual$other = actual$total - (actual$automotive + actual$food_beverage + actual$clothing + actual$ecommerce + actual$general_merchandise)

      sectors_all = c("total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other")
      rmse <- function(pred, act) sqrt(mean((pred - act)^2))

      rows <- list()
      for (s in sectors_all) {
        act   = actual[[s]]
        n_p   = retail_r_arima[[paste0("naive_", s)]]
        a_p   = retail_r_arima[[paste0("arima_", s)]]
        e_p   = retail_r_arima[[paste0("ets_", s)]]
        m_p   = retail_r_arima[[paste0("mint_", s)]]
        t5_p  = retail_timestral_5m[[paste0("t5m_", s)]]
        t20_p = retail_timestral_209m[[paste0("t209m_", s)]]

        n_rmse = rmse(n_p, act)

        t5m_bu_val  = if (s == "total") round(rmse(retail_timestral_5m$t5m_bottom_up, act), 1) else round(rmse(t5_p, act), 1)
        t20m_bu_val = if (s == "total") round(rmse(retail_timestral_209m$t209m_bottom_up, act), 1) else round(rmse(t20_p, act), 1)

        rows[[s]] = data.frame(
          sector         = s,
          naive_rmse     = round(n_rmse, 1),
          arima_rmse     = round(rmse(a_p, act), 1),
          ets_rmse       = round(rmse(e_p, act), 1),
          mint_ets_rmse  = round(rmse(m_p, act), 1),
          t5m_rmse       = round(rmse(t5_p, act), 1),
          t5m_bu_rmse    = t5m_bu_val,
          t209m_rmse     = round(rmse(t20_p, act), 1),
          t209m_bu_rmse  = t20m_bu_val
        )
      }

      # Compute coherence table row
      # Coherence error = max |Total - sum(Sectors)|
      bu_ets = retail_r_arima$ets_automotive + retail_r_arima$ets_food_beverage + retail_r_arima$ets_clothing + retail_r_arima$ets_ecommerce + retail_r_arima$ets_general_merchandise + retail_r_arima$ets_other
      coh_ets_base = max(abs(retail_r_arima$ets_total - bu_ets))
      coh_mint     = max(retail_r_arima$mint_coherence_max_error)
      coh_t5m_base = max(abs(retail_timestral_5m$t5m_total - retail_timestral_5m$t5m_bottom_up))
      coh_t20_base = max(abs(retail_timestral_209m$t209m_total - retail_timestral_209m$t209m_bottom_up))

      coh_row = data.frame(
        sector         = "[Incoherence_Abs_Max]",
        naive_rmse     = 0.0,
        arima_rmse     = round(coh_ets_base, 1),
        ets_rmse       = round(coh_ets_base, 1),
        mint_ets_rmse  = round(coh_mint, 8),
        t5m_rmse       = round(coh_t5m_base, 1),
        t5m_bu_rmse    = 0.0,
        t209m_rmse     = round(coh_t20_base, 1),
        t209m_bu_rmse  = 0.0
      )

      retail_benchmark_metrics = rbind(do.call(rbind, rows), coh_row)
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
  -- STUDY 3: Macro Triad & Monetary Policy Shocks (VAR, ARIMAX & Covariates)
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

      # 1. Naive baselines
      naive_cpi    = rep(tail(train$cpi, 1), 12)
      naive_unrate = rep(tail(train$unrate, 1), 12)

      # 2. Ex-ante Unconditional ARIMA
      fit_cpi_arima    = auto.arima(ts(train$cpi, frequency = 12))
      fc_cpi_arima     = as.numeric(forecast(fit_cpi_arima, h = 12)$mean)
      fit_unrate_arima = auto.arima(ts(train$unrate, frequency = 12))
      fc_unrate_arima  = as.numeric(forecast(fit_unrate_arima, h = 12)$mean)

      # 3. Ex-ante Unconditional VAR with dynamic AIC lag selection
      ts_train = ts(train[, c("cpi", "unrate", "fedfunds")], frequency = 12)
      sel = VARselect(ts_train, lag.max = 8, type = "both")
      opt_p = as.integer(sel$selection["AIC(n)"])
      fit_var = VAR(ts_train, p = opt_p, type = "both")
      pred_var = predict(fit_var, n.ahead = 12)$fcst

      # 4. Conditional Scenario ARIMAX with realized (oracle) FEDFUNDS
      fit_cpi_arimax = auto.arima(ts(train$cpi, frequency = 12), xreg = train$fedfunds)
      fc_cpi_arimax = as.numeric(forecast(fit_cpi_arimax, xreg = test$fedfunds, h = 12)$mean)

      fit_unrate_arimax = auto.arima(ts(train$unrate, frequency = 12), xreg = train$fedfunds)
      fc_unrate_arimax = as.numeric(forecast(fit_unrate_arimax, xreg = test$fedfunds, h = 12)$mean)

      macro_r_models = data.frame(
        step          = 1:12,
        naive_cpi     = naive_cpi,
        naive_unrate  = naive_unrate,
        arima_cpi     = fc_cpi_arima,
        arima_unrate  = fc_unrate_arima,
        var_cpi       = as.numeric(pred_var$cpi[, "fcst"]),
        var_unrate    = as.numeric(pred_var$unrate[, "fcst"]),
        arimax_cpi    = fc_cpi_arimax,
        arimax_unrate = fc_unrate_arimax,
        var_lag       = rep(opt_p, 12)
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

# 1. Pure univariate forecasts (ex-ante)
cpi_univ = fc.forecast(train["cpi"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()
unrate_univ = fc.forecast(train["unrate"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()

# 2. Conditional scenario forecasts with realized FEDFUNDS known_covariates
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

# 1. Pure univariate forecasts (ex-ante)
cpi_univ = fc.forecast(train["cpi"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()
unrate_univ = fc.forecast(train["unrate"].values, prediction_length=12).median.cpu().numpy().squeeze().tolist()

# 2. Conditional scenario forecasts with realized FEDFUNDS known_covariates
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

      # CPI models
      act_c = actual$cpi
      n_rmse_c = rmse(macro_r_models$naive_cpi, act_c)

      cpi_df = data.frame(
        target = "CPI (Inflation)",
        regime = c("Ex-ante Inconditionnel", "Ex-ante Inconditionnel", "Ex-ante Inconditionnel",
                   "Ex-ante Inconditionnel", "Ex-ante Inconditionnel",
                   "Conditionnel (Oracle FedFunds)", "Conditionnel (Oracle FedFunds)", "Conditionnel (Oracle FedFunds)"),
        model  = c("Naive (Dernière valeur)", "R ARIMA", "VAR (AIC lag)", "Timestral-5M Univarié", "Timestral-209M Univarié",
                   "ARIMAX (avec FedFunds)", "Timestral-5M (avec FedFunds)", "Timestral-209M (avec FedFunds)"),
        rmse   = round(c(
          n_rmse_c,
          rmse(macro_r_models$arima_cpi, act_c),
          rmse(macro_r_models$var_cpi, act_c),
          rmse(macro_timestral_5m$t5m_cpi_univ, act_c),
          rmse(macro_timestral_209m$t209m_cpi_univ, act_c),
          rmse(macro_r_models$arimax_cpi, act_c),
          rmse(macro_timestral_5m$t5m_cpi_cov, act_c),
          rmse(macro_timestral_209m$t209m_cpi_cov, act_c)
        ), 3),
        relative_rmse = round(c(
          1.000,
          rmse(macro_r_models$arima_cpi, act_c) / n_rmse_c,
          rmse(macro_r_models$var_cpi, act_c) / n_rmse_c,
          rmse(macro_timestral_5m$t5m_cpi_univ, act_c) / n_rmse_c,
          rmse(macro_timestral_209m$t209m_cpi_univ, act_c) / n_rmse_c,
          rmse(macro_r_models$arimax_cpi, act_c) / n_rmse_c,
          rmse(macro_timestral_5m$t5m_cpi_cov, act_c) / n_rmse_c,
          rmse(macro_timestral_209m$t209m_cpi_cov, act_c) / n_rmse_c
        ), 3)
      )

      # UNRATE models
      act_u = actual$unrate
      n_rmse_u = rmse(macro_r_models$naive_unrate, act_u)

      unrate_df = data.frame(
        target = "UNRATE (Chômage)",
        regime = c("Ex-ante Inconditionnel", "Ex-ante Inconditionnel", "Ex-ante Inconditionnel",
                   "Ex-ante Inconditionnel", "Ex-ante Inconditionnel",
                   "Conditionnel (Oracle FedFunds)", "Conditionnel (Oracle FedFunds)", "Conditionnel (Oracle FedFunds)"),
        model  = c("Naive (Dernière valeur)", "R ARIMA", "VAR (AIC lag)", "Timestral-5M Univarié", "Timestral-209M Univarié",
                   "ARIMAX (avec FedFunds)", "Timestral-5M (avec FedFunds)", "Timestral-209M (avec FedFunds)"),
        rmse   = round(c(
          n_rmse_u,
          rmse(macro_r_models$arima_unrate, act_u),
          rmse(macro_r_models$var_unrate, act_u),
          rmse(macro_timestral_5m$t5m_unrate_univ, act_u),
          rmse(macro_timestral_209m$t209m_unrate_univ, act_u),
          rmse(macro_r_models$arimax_unrate, act_u),
          rmse(macro_timestral_5m$t5m_unrate_cov, act_u),
          rmse(macro_timestral_209m$t209m_unrate_cov, act_u)
        ), 3),
        relative_rmse = round(c(
          1.000,
          rmse(macro_r_models$arima_unrate, act_u) / n_rmse_u,
          rmse(macro_r_models$var_unrate, act_u) / n_rmse_u,
          rmse(macro_timestral_5m$t5m_unrate_univ, act_u) / n_rmse_u,
          rmse(macro_timestral_209m$t209m_unrate_univ, act_u) / n_rmse_u,
          rmse(macro_r_models$arimax_unrate, act_u) / n_rmse_u,
          rmse(macro_timestral_5m$t5m_unrate_cov, act_u) / n_rmse_u,
          rmse(macro_timestral_209m$t209m_unrate_cov, act_u) / n_rmse_u
        ), 3)
      )

      macro_benchmark_metrics = rbind(cpi_df, unrate_df)
      rownames(macro_benchmark_metrics) <- NULL
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
  report = node(
    script = "src/report.qmd",
    runtime = Quarto,
    deps = [benchmark_metrics, cpi_probabilistic_metrics, retail_benchmark_metrics, macro_benchmark_metrics]
  )
}

-- Materialize and build
populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- Explicit error checking for all 17 pipeline nodes (AGENTS.md Rule 5)
nodes_to_guard = [
  "raw_data", "r_arima", "timestral_5m", "timestral_209m", "benchmark_metrics", "cpi_probabilistic_metrics",
  "retail_raw_data", "retail_r_arima", "retail_timestral_5m", "retail_timestral_209m", "retail_benchmark_metrics",
  "macro_raw_data", "macro_r_models", "macro_timestral_5m", "macro_timestral_209m", "macro_benchmark_metrics",
  "report"
]

if (is_error(p.raw_data)) { error(str_join(["Node 'raw_data' errored: ", error_msg(p.raw_data)])) }
if (is_error(p.r_arima)) { error(str_join(["Node 'r_arima' errored: ", error_msg(p.r_arima)])) }
if (is_error(p.timestral_5m)) { error(str_join(["Node 'timestral_5m' errored: ", error_msg(p.timestral_5m)])) }
if (is_error(p.timestral_209m)) { error(str_join(["Node 'timestral_209m' errored: ", error_msg(p.timestral_209m)])) }
if (is_error(p.benchmark_metrics)) { error(str_join(["Node 'benchmark_metrics' errored: ", error_msg(p.benchmark_metrics)])) }
if (is_error(p.cpi_probabilistic_metrics)) { error(str_join(["Node 'cpi_probabilistic_metrics' errored: ", error_msg(p.cpi_probabilistic_metrics)])) }
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

-- Substantive assertions with built-in check() (Rule 5)
check(expect_nodes(p, nodes_to_guard))

cpi_metrics = read_node(p.benchmark_metrics)
check(expect_nrow(cpi_metrics, 7))

cpi_prob = read_node(p.cpi_probabilistic_metrics)
check(expect_nrow(cpi_prob, 4))

retail_metrics = read_node(p.retail_benchmark_metrics)
check(expect_nrow(retail_metrics, 8))

macro_metrics = read_node(p.macro_benchmark_metrics)
check(expect_nrow(macro_metrics, 16))

-- Verify metrics DataFrames contain no missing values
check(expect_no_na(cpi_metrics))
check(expect_no_na(cpi_prob))
check(expect_no_na(retail_metrics))
check(expect_no_na(macro_metrics))

print("✓ timestral_demo: all 17 nodes and substantive assertions passed successfully!")

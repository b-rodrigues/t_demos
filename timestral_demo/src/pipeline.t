-- timestral_demo: Multi-Study Methodological Benchmark of Timestral (5M & 209M)
-- vs Econometric Models (ARIMA, ETS, MinT-shrink, VAR, ARIMAX) with Probabilistic
-- Evaluation (WIS, CRPS, Pinball), Context-Length Ablation, and Rolling-Origin Diebold-Mariano Tests

p = pipeline {
  ----------------------------------------------------------------------------
  -- STUDY 1: Canonical Inflation Benchmark (CPIAUCSL, 2010-2024)
  ----------------------------------------------------------------------------
  raw_data = node(
    command = read_csv("data/cpi.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  r_arima = rn(
    command = <{
      library(forecast)
      source("src/helpers.R")

      train_cpi = head(raw_data$cpi, -12)
      ts_train  = ts(train_cpi, frequency = 12)
      last_val  = tail(train_cpi, 1)

      # 1. Naive & Drift baselines
      fc_naive = rep(last_val, 12)
      fc_drift = as.numeric(rwf(ts_train, h = 12, drift = TRUE)$mean)

      # 2. Dynamic ARIMA with direct forecast(..., level = ...) quantiles
      fit_arima  = auto.arima(ts_train, seasonal = TRUE)
      fc_arima   = as.numeric(forecast(fit_arima, h = 12)$mean)
      q_arima    = forecast_quantiles(fit_arima, h = 12, simulate = FALSE)
      arima_spec = paste0("ARIMA(", paste(arimaorder(fit_arima), collapse = ","), ")")

      # 3. State-Space Exponential Smoothing (ETS) with simulated state-space quantiles
      # (handles multiplicative error structures such as ETS(M,A,N) without Gaussian symmetry assumption)
      fit_ets    = ets(ts_train)
      fc_ets     = as.numeric(forecast(fit_ets, h = 12)$mean)
      q_ets      = forecast_quantiles(fit_ets, h = 12, simulate = TRUE, npaths = 5000, seed = 2024)
      ets_spec   = fit_ets$method

      # 4. Hybrid Ensemble (ARIMA + ETS) / 2
      fc_ens     = (fc_arima + fc_ets) / 2
      q_ens      = 0.5 * (q_arima + q_ets)

      out = data.frame(
        step       = 1:12,
        naive      = fc_naive,
        drift      = fc_drift,
        arima      = fc_arima,
        arima_spec = rep(arima_spec, 12),
        ets        = fc_ets,
        ets_spec   = rep(ets_spec, 12),
        ensemble   = fc_ens
      )
      for (cn in colnames(q_arima)) {
        out[[paste0("ari_", cn)]] = q_arima[, cn]
        out[[paste0("ets_", cn)]] = q_ets[, cn]
        out[[paste0("ens_", cn)]] = q_ens[, cn]
      }
      r_arima = out
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  timestral_5m = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

cpi_vals = raw_data["cpi"].values[:-12].copy()
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")
res = fc.forecast(cpi_vals, prediction_length=12)
preds = res.median.cpu().numpy().squeeze().tolist()
q_mat = res.quantiles.cpu().numpy().squeeze()
q_levels = list(res.quantile_levels)

data_dict = {"step": list(range(1, 13)), "timestral_5m": preds}
for i, lvl in enumerate(q_levels):
    col_name = f"q_{int(round(lvl * 100)):02d}"
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

cpi_vals = raw_data["cpi"].values[:-12].copy()
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")
res = fc.forecast(cpi_vals, prediction_length=12)
preds = res.median.cpu().numpy().squeeze().tolist()
q_mat = res.quantiles.cpu().numpy().squeeze()
q_levels = list(res.quantile_levels)

data_dict = {"step": list(range(1, 13)), "timestral_209m": preds}
for i, lvl in enumerate(q_levels):
    col_name = f"q_{int(round(lvl * 100)):02d}"
    data_dict[col_name] = q_mat[:, i].tolist()

timestral_209m = pd.DataFrame(data_dict)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  benchmark_metrics = rn(
    command = <{
      source("src/helpers.R")
      actual = tail(raw_data$cpi, 12)
      last_train = tail(head(raw_data$cpi, -12), 1)
      calc_inf <- function(pred) (tail(pred, 1) - last_train) / last_train * 100

      ari_spec = as.character(r_arima$arima_spec[1])
      ets_spec = as.character(r_arima$ets_spec[1])

      models_list = list(
        list(name = "Naive (Marche aléatoire)",  spec = "RW(0)",                   pred = r_arima$naive),
        list(name = "RW avec Dérive (Drift)",     spec = "RW+drift",                pred = r_arima$drift),
        list(name = "R ARIMA (AIC)",              spec = ari_spec,                  pred = r_arima$arima),
        list(name = "R ETS (Espace d'états)",     spec = ets_spec,                  pred = r_arima$ets),
        list(name = "R Ensemble (ARIMA+ETS)",     spec = paste0(ari_spec, "+", ets_spec), pred = r_arima$ensemble),
        list(name = "Timestral-5M (Zero-shot)",   spec = "Patch=32, 5M, L=168",     pred = timestral_5m$timestral_5m),
        list(name = "Timestral-209M (Zero-shot)", spec = "Patch=32, 209M, L=168",   pred = timestral_209m$timestral_209m)
      )

      naive_rmse = rmse(r_arima$naive, actual)
      actual_inf = round((tail(actual, 1) - last_train) / last_train * 100, 2)

      rows = lapply(models_list, function(m) {
        m_rmse = rmse(m$pred, actual)
        data.frame(
          model             = m$name,
          specification     = m$spec,
          rmse              = round(m_rmse, 4),
          mae               = round(mae(m$pred, actual), 4),
          relative_rmse     = round(m_rmse / naive_rmse, 3),
          implied_inflation = round(calc_inf(m$pred), 2),
          actual_inflation  = actual_inf
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
      source("src/helpers.R")
      actual = tail(raw_data$cpi, 12)

      # Dynamically discover quantile columns from Timestral output (never hardcoded)
      q_cols = quantile_cols(timestral_5m)
      stopifnot(check_grid(q_cols), identical(q_cols, quantile_cols(timestral_209m)))

      ari_q = as.matrix(r_arima[, paste0("ari_", q_cols)])
      colnames(ari_q) = q_cols

      ets_q = as.matrix(r_arima[, paste0("ets_", q_cols)])
      colnames(ets_q) = q_cols

      ens_q = as.matrix(r_arima[, paste0("ens_", q_cols)])
      colnames(ens_q) = q_cols

      t5m_q   = as.matrix(timestral_5m[, q_cols])
      t209m_q = as.matrix(timestral_209m[, q_cols])

      ari_spec = as.character(r_arima$arima_spec[1])
      ets_spec = as.character(r_arima$ets_spec[1])

      prob_list = list(
        cbind(data.frame(model = "R ARIMA",        dist_method = paste0(ari_spec, " (analytique)")),      summarise_scores(score_rows(actual, ari_q))),
        cbind(data.frame(model = "R ETS",          dist_method = paste0(ets_spec, " (simulé, B=5000)")),  summarise_scores(score_rows(actual, ets_q))),
        cbind(data.frame(model = "R Ensemble",     dist_method = "Moyenne de quantiles (ARIMA+ETS)"),     summarise_scores(score_rows(actual, ens_q))),
        cbind(data.frame(model = "Timestral-5M",   dist_method = "21 quantiles natifs (L=168)"),          summarise_scores(score_rows(actual, t5m_q))),
        cbind(data.frame(model = "Timestral-209M", dist_method = "21 quantiles natifs (L=168)"),          summarise_scores(score_rows(actual, t209m_q)))
      )

      cpi_probabilistic_metrics = do.call(rbind, prob_list)
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
  -- STUDY 2: Multi-Sector Retail Sales, Correlation-Standardized MinT-shrink
  -- Reconciliation (for ETS, ARIMA, Timestral-5M & Timestral-209M) & WIS/CRPS
  ----------------------------------------------------------------------------
  retail_raw_data = node(
    command = read_csv("data/retail_sales.csv", separator = ","),
    runtime = T,
    serializer = ^csv
  )

  retail_r_arima = rn(
    command = <{
      library(forecast)
      source("src/helpers.R")

      train = head(retail_raw_data, -12)
      test  = tail(retail_raw_data, 12)
      for (nm in c("train", "test")) {
        d = get(nm)
        d$other = d$total - (d$automotive + d$food_beverage + d$clothing + d$ecommerce + d$general_merchandise)
        assign(nm, d)
      }

      sectors_5      = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise")
      sectors_all    = c("total", sectors_5, "other")
      sectors_bottom = c(sectors_5, "other")

      fcasts_ets = list()
      fcasts_ari = list()
      res_ets    = list()
      res_ari    = list()
      wis_ets    = numeric(length(sectors_all))
      wis_ari    = numeric(length(sectors_all))
      crps_ets   = numeric(length(sectors_all))
      crps_ari   = numeric(length(sectors_all))
      names(wis_ets) = names(wis_ari) = names(crps_ets) = names(crps_ari) = sectors_all

      for (s in sectors_all) {
        y_ts = ts(train[[s]], frequency = 12)
        act  = test[[s]]

        fit_e = ets(y_ts)
        fcasts_ets[[s]] = as.numeric(forecast(fit_e, h = 12)$mean)
        res_ets[[s]]    = as.numeric(residuals(fit_e, type = "response"))
        sc_e            = score_rows(act, forecast_quantiles(fit_e, h = 12, simulate = TRUE, npaths = 2000, seed = 2024))
        wis_ets[s]      = mean(sc_e$wis)
        crps_ets[s]     = mean(sc_e$crps)

        fit_a = auto.arima(y_ts)
        fcasts_ari[[s]] = as.numeric(forecast(fit_a, h = 12)$mean)
        res_ari[[s]]    = as.numeric(residuals(fit_a, type = "response"))
        sc_a            = score_rows(act, forecast_quantiles(fit_a, h = 12, simulate = FALSE))
        wis_ari[s]      = mean(sc_a$wis)
        crps_ari[s]     = mean(sc_a$crps)
      }

      # Correlation-standardized Schäfer-Strimmer (2005) MinT-shrink reconciliation
      # (identical to hts:::shrink.estim, invariant to relative series scale)
      S = rbind(rep(1, 6), diag(6))
      rownames(S) = sectors_all
      colnames(S) = sectors_bottom

      base_ets = do.call(cbind, fcasts_ets)
      base_ari = do.call(cbind, fcasts_ari)
      sh_ets   = shrink_cov(do.call(cbind, res_ets))
      sh_ari   = shrink_cov(do.call(cbind, res_ari))
      m_ets    = mint(base_ets, sh_ets$W, S)
      m_ari    = mint(base_ari, sh_ari$W, S)

      res = data.frame(
        step                     = 1:12,
        ets_lambda               = rep(sh_ets$lambda, 12),
        arima_lambda             = rep(sh_ari$lambda, 12),
        mint_ets_coherence_err   = rep(m_ets$coh_err, 12),
        mint_arima_coherence_err = rep(m_ari$coh_err, 12)
      )
      for (s in sectors_all) {
        res[[paste0("naive_", s)]]      = rep(tail(train[[s]], 1), 12)
        res[[paste0("arima_", s)]]      = base_ari[, s]
        res[[paste0("mint_arima_", s)]] = m_ari$rec[, s]
        res[[paste0("ets_", s)]]        = base_ets[, s]
        res[[paste0("mint_ets_", s)]]   = m_ets$rec[, s]
        res[[paste0("wis_ets_", s)]]    = rep(wis_ets[s], 12)
        res[[paste0("wis_arima_", s)]]  = rep(wis_ari[s], 12)
        res[[paste0("crps_ets_", s)]]   = rep(crps_ets[s], 12)
        res[[paste0("crps_arima_", s)]] = rep(crps_ari[s], 12)
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
test  = retail_raw_data.iloc[-12:].copy()
for d in (train, test):
    d["other"] = d["total"] - (d["automotive"] + d["food_beverage"] + d["clothing"] + d["ecommerce"] + d["general_merchandise"])

sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

# 1. Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
res_list = []
for o in range(120, mat_train.shape[1]):
    p1 = fc.forecast(mat_train[:, :o].copy(), prediction_length=1).median.cpu().numpy().squeeze()
    res_list.append(mat_train[:, o] - p1)
res_mat = np.stack(res_list, axis=0)  # (48, 7)

# Correlation-standardized Schäfer-Strimmer shrinkage
n = res_mat.shape[0]
covm = (res_mat.T @ res_mat) / n
tar = np.diag(np.diag(covm))
sd = np.sqrt(np.diag(covm))
corm = covm / np.outer(sd, sd)
xs = res_mat / sd[np.newaxis, :]
v = (1.0 / (n * (n - 1))) * ((xs ** 2).T @ (xs ** 2) - ((xs.T @ xs) ** 2) / n)
np.fill_diagonal(v, 0.0)
d_mat = (corm - np.eye(len(sectors_all))) ** 2
lam = float(np.clip(np.sum(v) / np.sum(d_mat), 0.0, 1.0))
W = lam * tar + (1.0 - lam) * covm
S = np.vstack([np.ones((1, 6)), np.eye(6)])
Wi = np.linalg.inv(W)
P_mint = np.linalg.solve(S.T @ Wi @ S, S.T @ Wi)

# 2. Forecast 12 steps + quantiles for all 7 series
res = {"step": list(range(1, 13)), "t5m_lambda": [lam] * 12}
base_cols = []
for s in sectors_all:
    vals = train[s].values.copy()
    f_out = fc.forecast(vals, prediction_length=12)
    med = f_out.median.cpu().numpy().squeeze()
    q_mat = f_out.quantiles.cpu().numpy().squeeze()
    tau = np.array(f_out.quantile_levels)
    act = test[s].values[:, np.newaxis]
    L = np.where(act >= q_mat, tau * (act - q_mat), (1.0 - tau) * (q_mat - act))
    K = (len(tau) - 1) / 2.0
    bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
    wis_val = float(np.mean(np.sum(L, axis=1) / (K + 0.5)))
    crps_val = float(np.mean(2.0 * (L @ np.diff(bounds))))
    res[f"t5m_{s}"] = med.tolist()
    res[f"wis_t5m_{s}"] = [wis_val] * 12
    res[f"crps_t5m_{s}"] = [crps_val] * 12
    base_cols.append(med)

base_mat = np.stack(base_cols, axis=1)  # (12, 7)
rec_mat = (S @ P_mint @ base_mat.T).T
coh_err = float(np.max(np.abs(rec_mat[:, 0] - np.sum(rec_mat[:, 1:], axis=1))))
res["mint_t5m_coherence_err"] = [coh_err] * 12
for i, s in enumerate(sectors_all):
    res[f"mint_t5m_{s}"] = rec_mat[:, i].tolist()

res_df = pd.DataFrame(res)
res_df["t5m_bottom_up"] = (
    res_df["t5m_automotive"] + res_df["t5m_food_beverage"] + res_df["t5m_clothing"]
    + res_df["t5m_ecommerce"] + res_df["t5m_general_merchandise"] + res_df["t5m_other"]
)
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
test  = retail_raw_data.iloc[-12:].copy()
for d in (train, test):
    d["other"] = d["total"] - (d["automotive"] + d["food_beverage"] + d["clothing"] + d["ecommerce"] + d["general_merchandise"])

sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

# 1. Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
res_list = []
for o in range(120, mat_train.shape[1]):
    p1 = fc.forecast(mat_train[:, :o].copy(), prediction_length=1).median.cpu().numpy().squeeze()
    res_list.append(mat_train[:, o] - p1)
res_mat = np.stack(res_list, axis=0)  # (48, 7)

# Correlation-standardized Schäfer-Strimmer shrinkage
n = res_mat.shape[0]
covm = (res_mat.T @ res_mat) / n
tar = np.diag(np.diag(covm))
sd = np.sqrt(np.diag(covm))
corm = covm / np.outer(sd, sd)
xs = res_mat / sd[np.newaxis, :]
v = (1.0 / (n * (n - 1))) * ((xs ** 2).T @ (xs ** 2) - ((xs.T @ xs) ** 2) / n)
np.fill_diagonal(v, 0.0)
d_mat = (corm - np.eye(len(sectors_all))) ** 2
lam = float(np.clip(np.sum(v) / np.sum(d_mat), 0.0, 1.0))
W = lam * tar + (1.0 - lam) * covm
S = np.vstack([np.ones((1, 6)), np.eye(6)])
Wi = np.linalg.inv(W)
P_mint = np.linalg.solve(S.T @ Wi @ S, S.T @ Wi)

# 2. Forecast 12 steps + quantiles for all 7 series
res = {"step": list(range(1, 13)), "t209m_lambda": [lam] * 12}
base_cols = []
for s in sectors_all:
    vals = train[s].values.copy()
    f_out = fc.forecast(vals, prediction_length=12)
    med = f_out.median.cpu().numpy().squeeze()
    q_mat = f_out.quantiles.cpu().numpy().squeeze()
    tau = np.array(f_out.quantile_levels)
    act = test[s].values[:, np.newaxis]
    L = np.where(act >= q_mat, tau * (act - q_mat), (1.0 - tau) * (q_mat - act))
    K = (len(tau) - 1) / 2.0
    bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
    wis_val = float(np.mean(np.sum(L, axis=1) / (K + 0.5)))
    crps_val = float(np.mean(2.0 * (L @ np.diff(bounds))))
    res[f"t209m_{s}"] = med.tolist()
    res[f"wis_t209m_{s}"] = [wis_val] * 12
    res[f"crps_t209m_{s}"] = [crps_val] * 12
    base_cols.append(med)

base_mat = np.stack(base_cols, axis=1)  # (12, 7)
rec_mat = (S @ P_mint @ base_mat.T).T
coh_err = float(np.max(np.abs(rec_mat[:, 0] - np.sum(rec_mat[:, 1:], axis=1))))
res["mint_t209m_coherence_err"] = [coh_err] * 12
for i, s in enumerate(sectors_all):
    res[f"mint_t209m_{s}"] = rec_mat[:, i].tolist()

res_df = pd.DataFrame(res)
res_df["t209m_bottom_up"] = (
    res_df["t209m_automotive"] + res_df["t209m_food_beverage"] + res_df["t209m_clothing"]
    + res_df["t209m_ecommerce"] + res_df["t209m_general_merchandise"] + res_df["t209m_other"]
)
retail_timestral_209m = res_df
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  retail_benchmark_metrics = rn(
    command = <{
      source("src/helpers.R")
      actual = tail(retail_raw_data, 12)
      actual$other = actual$total - (actual$automotive + actual$food_beverage + actual$clothing + actual$ecommerce + actual$general_merchandise)

      sectors_all = c("total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other")

      rows <- list()
      for (s in sectors_all) {
        act     = actual[[s]]
        n_p     = retail_r_arima[[paste0("naive_", s)]]
        a_p     = retail_r_arima[[paste0("arima_", s)]]
        ma_p    = retail_r_arima[[paste0("mint_arima_", s)]]
        e_p     = retail_r_arima[[paste0("ets_", s)]]
        me_p    = retail_r_arima[[paste0("mint_ets_", s)]]
        t5_p    = retail_timestral_5m[[paste0("t5m_", s)]]
        mt5_p   = retail_timestral_5m[[paste0("mint_t5m_", s)]]
        t20_p   = retail_timestral_209m[[paste0("t209m_", s)]]
        mt20_p  = retail_timestral_209m[[paste0("mint_t209m_", s)]]

        rows[[s]] = data.frame(
          sector          = s,
          naive_rmse      = round(rmse(n_p, act), 1),
          arima_rmse      = round(rmse(a_p, act), 1),
          mint_arima_rmse = round(rmse(ma_p, act), 1),
          ets_rmse        = round(rmse(e_p, act), 1),
          mint_ets_rmse   = round(rmse(me_p, act), 1),
          t5m_rmse        = round(rmse(t5_p, act), 1),
          mint_t5m_rmse   = round(rmse(mt5_p, act), 1),
          t209m_rmse      = round(rmse(t20_p, act), 1),
          mint_t209m_rmse = round(rmse(mt20_p, act), 1),
          wis_arima       = round(retail_r_arima[[paste0("wis_arima_", s)]][1], 1),
          wis_ets         = round(retail_r_arima[[paste0("wis_ets_", s)]][1], 1),
          wis_t5m         = round(retail_timestral_5m[[paste0("wis_t5m_", s)]][1], 1),
          wis_t209m       = round(retail_timestral_209m[[paste0("wis_t209m_", s)]][1], 1)
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

  retail_coherence_metrics = rn(
    command = <{
      source("src/helpers.R")
      actual = tail(retail_raw_data, 12)
      actual$other = actual$total - (actual$automotive + actual$food_beverage + actual$clothing + actual$ecommerce + actual$general_merchandise)
      sectors_bottom = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other")
      sectors_all    = c("total", sectors_bottom)

      bu_ari = rowSums(sapply(sectors_bottom, function(s) retail_r_arima[[paste0("arima_", s)]]))
      bu_ets = rowSums(sapply(sectors_bottom, function(s) retail_r_arima[[paste0("ets_", s)]]))
      bu_t5m = retail_timestral_5m$t5m_bottom_up
      bu_t20 = retail_timestral_209m$t209m_bottom_up

      coh_ari_base = max(abs(retail_r_arima$arima_total - bu_ari))
      coh_ets_base = max(abs(retail_r_arima$ets_total - bu_ets))
      coh_t5m_base = max(abs(retail_timestral_5m$t5m_total - bu_t5m))
      coh_t20_base = max(abs(retail_timestral_209m$t209m_total - bu_t20))

      coh_mint_ari = retail_r_arima$mint_arima_coherence_err[1]
      coh_mint_ets = retail_r_arima$mint_ets_coherence_err[1]
      coh_mint_t5m = retail_timestral_5m$mint_t5m_coherence_err[1]
      coh_mint_t20 = retail_timestral_209m$mint_t209m_coherence_err[1]

      mean_bot_rmse <- function(df, prefix) {
        mean(sapply(sectors_bottom, function(s) rmse(df[[paste0(prefix, s)]], actual[[s]])))
      }

      retail_coherence_metrics = data.frame(
        method = c(
          "R ARIMA (Base non réconcilié)",
          "R ARIMA (Bottom-Up)",
          "R ARIMA (MinT-shrink)",
          "R ETS (Base non réconcilié)",
          "R ETS (Bottom-Up)",
          "R ETS (MinT-shrink)",
          "Timestral-5M (Base non réconcilié)",
          "Timestral-5M (Bottom-Up)",
          "Timestral-5M (MinT-shrink backtest)",
          "Timestral-209M (Base non réconcilié)",
          "Timestral-209M (Bottom-Up)",
          "Timestral-209M (MinT-shrink backtest)"
        ),
        is_reconciled = c(0L, 1L, 1L, 0L, 1L, 1L, 0L, 1L, 1L, 0L, 1L, 1L),
        shrinkage_lambda = round(c(
          0.0, 0.0, retail_r_arima$arima_lambda[1],
          0.0, 0.0, retail_r_arima$ets_lambda[1],
          0.0, 0.0, retail_timestral_5m$t5m_lambda[1],
          0.0, 0.0, retail_timestral_209m$t209m_lambda[1]
        ), 4),
        total_rmse = round(c(
          rmse(retail_r_arima$arima_total, actual$total),
          rmse(bu_ari, actual$total),
          rmse(retail_r_arima$mint_arima_total, actual$total),
          rmse(retail_r_arima$ets_total, actual$total),
          rmse(bu_ets, actual$total),
          rmse(retail_r_arima$mint_ets_total, actual$total),
          rmse(retail_timestral_5m$t5m_total, actual$total),
          rmse(bu_t5m, actual$total),
          rmse(retail_timestral_5m$mint_t5m_total, actual$total),
          rmse(retail_timestral_209m$t209m_total, actual$total),
          rmse(bu_t20, actual$total),
          rmse(retail_timestral_209m$mint_t209m_total, actual$total)
        ), 1),
        mean_bottom6_rmse = round(c(
          mean_bot_rmse(retail_r_arima, "arima_"),
          mean_bot_rmse(retail_r_arima, "arima_"),
          mean_bot_rmse(retail_r_arima, "mint_arima_"),
          mean_bot_rmse(retail_r_arima, "ets_"),
          mean_bot_rmse(retail_r_arima, "ets_"),
          mean_bot_rmse(retail_r_arima, "mint_ets_"),
          mean_bot_rmse(retail_timestral_5m, "t5m_"),
          mean_bot_rmse(retail_timestral_5m, "t5m_"),
          mean_bot_rmse(retail_timestral_5m, "mint_t5m_"),
          mean_bot_rmse(retail_timestral_209m, "t209m_"),
          mean_bot_rmse(retail_timestral_209m, "t209m_"),
          mean_bot_rmse(retail_timestral_209m, "mint_t209m_")
        ), 1),
        max_abs_incoherence = c(
          coh_ari_base, 0.0, coh_mint_ari,
          coh_ets_base, 0.0, coh_mint_ets,
          coh_t5m_base, 0.0, coh_mint_t5m,
          coh_t20_base, 0.0, coh_mint_t20
        ),
        max_abs_incoherence_sci = formatC(c(
          coh_ari_base, 0.0, coh_mint_ari,
          coh_ets_base, 0.0, coh_mint_ets,
          coh_t5m_base, 0.0, coh_mint_t5m,
          coh_t20_base, 0.0, coh_mint_t20
        ), format = "e", digits = 2)
      )
      retail_coherence_metrics
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
  -- STUDY 3: Macro Triad, Context-Length Ablation, & Rolling-Origin DM Tests
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
      source("src/helpers.R")

      train = head(macro_raw_data, -12)
      test  = tail(macro_raw_data, 12)

      # 1. Naive baselines
      naive_cpi    = rep(tail(train$cpi, 1), 12)
      naive_unrate = rep(tail(train$unrate, 1), 12)

      # 2. Ex-ante Unconditional ARIMA & ETS with predictive quantiles
      ts_cpi    = ts(train$cpi, frequency = 12)
      ts_unrate = ts(train$unrate, frequency = 12)

      fit_cpi_arima    = auto.arima(ts_cpi)
      fc_cpi_arima     = as.numeric(forecast(fit_cpi_arima, h = 12)$mean)
      q_cpi_arima      = forecast_quantiles(fit_cpi_arima, h = 12, simulate = FALSE)
      cpi_arima_spec   = paste0("ARIMA(", paste(arimaorder(fit_cpi_arima), collapse = ","), ")")

      fit_cpi_ets      = ets(ts_cpi)
      fc_cpi_ets       = as.numeric(forecast(fit_cpi_ets, h = 12)$mean)
      q_cpi_ets        = forecast_quantiles(fit_cpi_ets, h = 12, simulate = TRUE, npaths = 5000, seed = 2024)
      cpi_ets_spec     = fit_cpi_ets$method

      fit_unrate_arima  = auto.arima(ts_unrate)
      fc_unrate_arima   = as.numeric(forecast(fit_unrate_arima, h = 12)$mean)
      q_unrate_arima    = forecast_quantiles(fit_unrate_arima, h = 12, simulate = FALSE)
      unrate_arima_spec = paste0("ARIMA(", paste(arimaorder(fit_unrate_arima), collapse = ","), ")")

      fit_unrate_ets    = ets(ts_unrate)
      fc_unrate_ets     = as.numeric(forecast(fit_unrate_ets, h = 12)$mean)
      q_unrate_ets      = forecast_quantiles(fit_unrate_ets, h = 12, simulate = TRUE, npaths = 5000, seed = 2024)
      unrate_ets_spec   = fit_unrate_ets$method

      # 3. Ex-ante Unconditional VAR with dynamic AIC lag selection
      ts_train = ts(train[, c("cpi", "unrate", "fedfunds")], frequency = 12)
      sel      = VARselect(ts_train, lag.max = 8, type = "both")
      opt_p    = as.integer(sel$selection["AIC(n)"])
      fit_var  = VAR(ts_train, p = opt_p, type = "both")
      pred_var = predict(fit_var, n.ahead = 12)$fcst

      # 4. Conditional Scenario ARIMAX with realized (oracle) FEDFUNDS & predictive quantiles
      fit_cpi_arimax    = auto.arima(ts_cpi, xreg = train$fedfunds)
      fc_cpi_arimax     = as.numeric(forecast(fit_cpi_arimax, xreg = test$fedfunds, h = 12)$mean)
      q_cpi_arimax      = forecast_quantiles(fit_cpi_arimax, h = 12, xreg = test$fedfunds, simulate = FALSE)
      cpi_arimax_spec   = paste0("ARIMAX(", paste(arimaorder(fit_cpi_arimax), collapse = ","), ")")

      fit_unrate_arimax  = auto.arima(ts_unrate, xreg = train$fedfunds)
      fc_unrate_arimax   = as.numeric(forecast(fit_unrate_arimax, xreg = test$fedfunds, h = 12)$mean)
      q_unrate_arimax    = forecast_quantiles(fit_unrate_arimax, h = 12, xreg = test$fedfunds, simulate = FALSE)
      unrate_arimax_spec = paste0("ARIMAX(", paste(arimaorder(fit_unrate_arimax), collapse = ","), ")")

      out = data.frame(
        step               = 1:12,
        naive_cpi          = naive_cpi,
        naive_unrate       = naive_unrate,
        arima_cpi          = fc_cpi_arima,
        ets_cpi            = fc_cpi_ets,
        arima_unrate       = fc_unrate_arima,
        ets_unrate         = fc_unrate_ets,
        var_cpi            = as.numeric(pred_var$cpi[, "fcst"]),
        var_unrate         = as.numeric(pred_var$unrate[, "fcst"]),
        arimax_cpi         = fc_cpi_arimax,
        arimax_unrate      = fc_unrate_arimax,
        var_lag            = rep(opt_p, 12),
        cpi_arima_spec     = rep(cpi_arima_spec, 12),
        cpi_ets_spec       = rep(cpi_ets_spec, 12),
        cpi_arimax_spec    = rep(cpi_arimax_spec, 12),
        unrate_arima_spec  = rep(unrate_arima_spec, 12),
        unrate_ets_spec    = rep(unrate_ets_spec, 12),
        unrate_arimax_spec = rep(unrate_arimax_spec, 12)
      )
      for (cn in colnames(q_cpi_arima)) {
        out[[paste0("cpi_ari_", cn)]]    = q_cpi_arima[, cn]
        out[[paste0("cpi_ets_", cn)]]    = q_cpi_ets[, cn]
        out[[paste0("cpi_arx_", cn)]]    = q_cpi_arimax[, cn]
        out[[paste0("unr_ari_", cn)]]    = q_unrate_arima[, cn]
        out[[paste0("unr_ets_", cn)]]    = q_unrate_ets[, cn]
        out[[paste0("unr_arx_", cn)]]    = q_unrate_arimax[, cn]
      }
      macro_r_models = out
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

ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :].copy()
res_cpi_u = fc.forecast(train["cpi"].values.copy(), prediction_length=12)
res_cpi_c = fc.forecast(train["cpi"].values.copy(), prediction_length=12, known_covariates=ff_known)
res_unr_u = fc.forecast(train["unrate"].values.copy(), prediction_length=12)
res_unr_c = fc.forecast(train["unrate"].values.copy(), prediction_length=12, known_covariates=ff_known)

q_levels = list(res_cpi_u.quantile_levels)
data = {
    "step": list(range(1, 13)),
    "t5m_cpi_univ": res_cpi_u.median.cpu().numpy().squeeze().tolist(),
    "t5m_cpi_cov": res_cpi_c.median.cpu().numpy().squeeze().tolist(),
    "t5m_unrate_univ": res_unr_u.median.cpu().numpy().squeeze().tolist(),
    "t5m_unrate_cov": res_unr_c.median.cpu().numpy().squeeze().tolist(),
}
for tag, r_obj in [("cpi_u", res_cpi_u), ("cpi_c", res_cpi_c), ("unr_u", res_unr_u), ("unr_c", res_unr_c)]:
    qm = r_obj.quantiles.cpu().numpy().squeeze()
    for i, lvl in enumerate(q_levels):
        data[f"{tag}_q_{int(round(lvl * 100)):02d}"] = qm[:, i].tolist()

# Context-length ablation on the exact same CPI series & 2024 target window
full_cpi = train["cpi"].values
for L in [60, 120, 168, 240, 288]:
    r_ctx = fc.forecast(full_cpi[-L:].copy(), prediction_length=12)
    data[f"ctx_{L}_med"] = r_ctx.median.cpu().numpy().squeeze().tolist()

macro_timestral_5m = pd.DataFrame(data)
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

ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :].copy()
res_cpi_u = fc.forecast(train["cpi"].values.copy(), prediction_length=12)
res_cpi_c = fc.forecast(train["cpi"].values.copy(), prediction_length=12, known_covariates=ff_known)
res_unr_u = fc.forecast(train["unrate"].values.copy(), prediction_length=12)
res_unr_c = fc.forecast(train["unrate"].values.copy(), prediction_length=12, known_covariates=ff_known)

q_levels = list(res_cpi_u.quantile_levels)
data = {
    "step": list(range(1, 13)),
    "t209m_cpi_univ": res_cpi_u.median.cpu().numpy().squeeze().tolist(),
    "t209m_cpi_cov": res_cpi_c.median.cpu().numpy().squeeze().tolist(),
    "t209m_unrate_univ": res_unr_u.median.cpu().numpy().squeeze().tolist(),
    "t209m_unrate_cov": res_unr_c.median.cpu().numpy().squeeze().tolist(),
}
for tag, r_obj in [("cpi_u", res_cpi_u), ("cpi_c", res_cpi_c), ("unr_u", res_unr_u), ("unr_c", res_unr_c)]:
    qm = r_obj.quantiles.cpu().numpy().squeeze()
    for i, lvl in enumerate(q_levels):
        data[f"{tag}_q_{int(round(lvl * 100)):02d}"] = qm[:, i].tolist()

# Context-length ablation on the exact same CPI series & 2024 target window
full_cpi = train["cpi"].values
for L in [60, 120, 168, 240, 288]:
    r_ctx = fc.forecast(full_cpi[-L:].copy(), prediction_length=12)
    data[f"ctx_{L}_med"] = r_ctx.median.cpu().numpy().squeeze().tolist()

macro_timestral_209m = pd.DataFrame(data)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  macro_benchmark_metrics = rn(
    command = <{
      source("src/helpers.R")
      actual = tail(macro_raw_data, 12)
      q_cols = q_names()

      get_q <- function(df, prefix) {
        m = as.matrix(df[, paste0(prefix, q_cols)])
        colnames(m) = q_cols
        m
      }

      var_p   = macro_r_models$var_lag[1]
      var_lbl = paste0("VAR(p=", var_p, ", AIC)")

      build_row <- function(target_lbl, act, n_rmse, regime_lbl, mod_lbl, spec_lbl, pred, qmat = NULL) {
        r_val = rmse(pred, act)
        if (is.null(qmat)) {
          sc = data.frame(wis = NA_real_, crps = NA_real_, mean_pinball = NA_real_,
                          coverage_80 = NA_real_, coverage_90 = NA_real_, width_80 = NA_real_, width_90 = NA_real_, crossings = 0L)
        } else {
          sc = summarise_scores(score_rows(act, qmat), digits = 3)
        }
        cbind(
          data.frame(
            target        = target_lbl,
            regime        = regime_lbl,
            model         = mod_lbl,
            specification = spec_lbl,
            rmse          = round(r_val, 3),
            relative_rmse = round(r_val / n_rmse, 3)
          ),
          sc
        )
      }

      act_c = actual$cpi
      n_c   = rmse(macro_r_models$naive_cpi, act_c)
      act_u = actual$unrate
      n_u   = rmse(macro_r_models$naive_unrate, act_u)

      rows = list(
        # CPI
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_cpi, NULL),
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$cpi_arima_spec[1]), macro_r_models$arima_cpi, get_q(macro_r_models, "cpi_ari_")),
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$cpi_ets_spec[1]), macro_r_models$ets_cpi, get_q(macro_r_models, "cpi_ets_")),
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_cpi, NULL),
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_cpi_univ, get_q(macro_timestral_5m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_cpi_univ, get_q(macro_timestral_209m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$cpi_arimax_spec[1]), macro_r_models$arimax_cpi, get_q(macro_r_models, "cpi_arx_")),
        build_row("CPI (Inflation)", act_c, n_c, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_cpi_cov, get_q(macro_timestral_5m, "cpi_c_")),
        build_row("CPI (Inflation)", act_c, n_c, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_cpi_cov, get_q(macro_timestral_209m, "cpi_c_")),
        # UNRATE
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_unrate, NULL),
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$unrate_arima_spec[1]), macro_r_models$arima_unrate, get_q(macro_r_models, "unr_ari_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$unrate_ets_spec[1]), macro_r_models$ets_unrate, get_q(macro_r_models, "unr_ets_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_unrate, NULL),
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_unrate_univ, get_q(macro_timestral_5m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_unrate_univ, get_q(macro_timestral_209m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$unrate_arimax_spec[1]), macro_r_models$arimax_unrate, get_q(macro_r_models, "unr_arx_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_unrate_cov, get_q(macro_timestral_5m, "unr_c_")),
        build_row("UNRATE (Chômage)", act_u, n_u, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_unrate_cov, get_q(macro_timestral_209m, "unr_c_"))
      )

      macro_benchmark_metrics = do.call(rbind, rows)
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
  -- STUDY 4: Multi-Origin Rolling Evaluation (24 Origins) & Diebold-Mariano
  -- Tests (Harvey Small-Sample Correction) + Context-Length Ablation
  ----------------------------------------------------------------------------
  rolling_timestral = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

N = len(macro_raw_data)  # 300
origins = list(range(N - 12 - 23, N - 12 + 1))  # 24 rolling origins: lengths 265..288

fc5   = TimestralForecaster.from_pretrained("models/Timestral-5M")
fc209 = TimestralForecaster.from_pretrained("models/Timestral-209M")

rows = []
for v in ["cpi", "unrate"]:
    y = macro_raw_data[v].values
    for idx, L in enumerate(origins):
        ctx = y[:L].copy()
        act = y[L : L + 12]
        for mname, fc in [("Timestral-5M", fc5), ("Timestral-209M", fc209)]:
            out = fc.forecast(ctx, prediction_length=12)
            med = out.median.cpu().numpy().squeeze()
            q_mat = out.quantiles.cpu().numpy().squeeze()
            tau = np.array(out.quantile_levels)
            act_col = act[:, np.newaxis]
            L_pin = np.where(act_col >= q_mat, tau * (act_col - q_mat), (1.0 - tau) * (q_mat - act_col))
            K = (len(tau) - 1) / 2.0
            bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
            wis_vec = np.sum(L_pin, axis=1) / (K + 0.5)
            crps_vec = 2.0 * (L_pin @ np.diff(bounds))
            q_cols = [f"q_{int(round(lvl * 100)):02d}" for lvl in tau]
            i10, i90 = q_cols.index("q_10"), q_cols.index("q_90")
            i05, i95 = q_cols.index("q_05"), q_cols.index("q_95")
            cov80 = float(np.mean((act >= q_mat[:, i10]) & (act <= q_mat[:, i90])))
            cov90 = float(np.mean((act >= q_mat[:, i05]) & (act <= q_mat[:, i95])))
            cross = int(np.sum(np.diff(q_mat, axis=1) < -1e-9))
            rows.append({
                "target": v,
                "origin_idx": idx + 1,
                "train_len": L,
                "model": mname,
                "err_h1": float(act[0] - med[0]),
                "err_h12": float(act[11] - med[11]),
                "rmse_12m": float(np.sqrt(np.mean((act - med) ** 2))),
                "wis_12m": float(np.mean(wis_vec)),
                "crps_12m": float(np.mean(crps_vec)),
                "cov80_12m": cov80,
                "cov90_12m": cov90,
                "crossings": cross,
            })

rolling_timestral = pd.DataFrame(rows)
    }>,
    deserializer = ^csv,
    serializer = ^csv
  )

  rolling_and_ablation_metrics = rn(
    command = <{
      library(forecast)
      source("src/helpers.R")

      # Part A: Context-Length Ablation on CPI (all windows ending in Dec 2023, predicting 2024)
      train_cpi = head(macro_raw_data$cpi, -12)
      test_cpi  = tail(macro_raw_data$cpi, 12)
      L_grid    = c(60, 120, 168, 240, 288)

      ctx_rows = lapply(L_grid, function(L) {
        sub_y = tail(train_cpi, L)
        start_date = switch(as.character(L),
          "60"  = "2019-01",
          "120" = "2014-01",
          "168" = "2010-01",
          "240" = "2004-01",
          "288" = "2000-01",
          "inconnu"
        )
        ts_sub = ts(sub_y, frequency = 12)
        fc_a = as.numeric(forecast(auto.arima(ts_sub, seasonal = FALSE), h = 12)$mean)
        fc_e = as.numeric(forecast(ets(ts_sub, model = "ZZN"), h = 12)$mean)
        p5   = macro_timestral_5m[[paste0("ctx_", L, "_med")]]
        p209 = macro_timestral_209m[[paste0("ctx_", L, "_med")]]
        data.frame(
          section        = "context_ablation",
          target         = "CPI (2024)",
          context_months = L,
          window_start   = as.character(start_date),
          model          = paste0("L=", L, "m (depuis ", start_date, ")"),
          arima_rmse     = round(rmse(fc_a, test_cpi), 4),
          ets_rmse       = round(rmse(fc_e, test_cpi), 4),
          t5m_rmse       = round(rmse(p5, test_cpi), 4),
          t209m_rmse     = round(rmse(p209, test_cpi), 4),
          dm_stat_h1     = 0.0,
          dm_pval_h1     = 1.0,
          dm_stat_h12    = 0.0,
          dm_pval_h12    = 1.0
        )
      })
      ctx_df = do.call(rbind, ctx_rows)

      # Part B: 24-Origin Rolling Evaluation & Harvey-corrected Diebold-Mariano Tests
      N = nrow(macro_raw_data)
      origins = (N - 12 - 23):(N - 12)  # 24 rolling origins

      roll_rows = list()
      for (v in c("cpi", "unrate")) {
        y = macro_raw_data[[v]]
        t_lbl = if (v == "cpi") "CPI (24 origines)" else "UNRATE (24 origines)"

        e1_n = e12_n = r12_n = numeric(length(origins))
        e1_a = e12_a = r12_a = w12_a = c80_a = numeric(length(origins))
        e1_e = e12_e = r12_e = w12_e = c80_e = numeric(length(origins))

        for (i in seq_along(origins)) {
          L = origins[i]
          tr = ts(y[1:L], frequency = 12)
          act = y[(L + 1):(L + 12)]

          p_n = rep(y[L], 12)
          fit_a = auto.arima(tr, seasonal = FALSE)
          p_a   = as.numeric(forecast(fit_a, h = 12)$mean)
          sc_a  = score_rows(act, forecast_quantiles(fit_a, h = 12, simulate = FALSE))

          fit_e = ets(tr, model = "ZZN")
          p_e   = as.numeric(forecast(fit_e, h = 12)$mean)
          sc_e  = score_rows(act, forecast_quantiles(fit_e, h = 12, simulate = FALSE))

          e1_n[i] = act[1] - p_n[1]; e12_n[i] = act[12] - p_n[12]; r12_n[i] = rmse(p_n, act)
          e1_a[i] = act[1] - p_a[1]; e12_a[i] = act[12] - p_a[12]; r12_a[i] = rmse(p_a, act)
          w12_a[i] = mean(sc_a$wis); c80_a[i] = mean(sc_a$in80)
          e1_e[i] = act[1] - p_e[1]; e12_e[i] = act[12] - p_e[12]; r12_e[i] = rmse(p_e, act)
          w12_e[i] = mean(sc_e$wis); c80_e[i] = mean(sc_e$in80)
        }

        sub_t5   = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-5M", ]
        sub_t209 = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-209M", ]
        sub_t5   = sub_t5[order(sub_t5$origin_idx), ]
        sub_t209 = sub_t209[order(sub_t209$origin_idx), ]

        # Harvey-corrected Diebold-Mariano tests against R ARIMA baseline
        dm_n_1    = dm_harvey(e1_n, e1_a, h = 1);             dm_n_12    = dm_harvey(e12_n, e12_a, h = 12)
        dm_e_1    = dm_harvey(e1_e, e1_a, h = 1);             dm_e_12    = dm_harvey(e12_e, e12_a, h = 12)
        dm_t5_1   = dm_harvey(sub_t5$err_h1, e1_a, h = 1);    dm_t5_12   = dm_harvey(sub_t5$err_h12, e12_a, h = 12)
        dm_t209_1 = dm_harvey(sub_t209$err_h1, e1_a, h = 1);  dm_t209_12 = dm_harvey(sub_t209$err_h12, e12_a, h = 12)

        # In the rolling rows:
        # arima_rmse  -> h=1 rolling RMSE
        # ets_rmse    -> h=12 rolling RMSE
        # t5m_rmse    -> mean 12-step trajectory RMSE across 24 origins
        # t209m_rmse  -> mean 12-step WIS across 24 origins (0 for Naive)
        roll_rows[[v]] = data.frame(
          section        = "rolling_24_origins",
          target         = t_lbl,
          context_months = as.integer(round( c(0, mean(c80_a), mean(c80_e), mean(sub_t5$cov80_12m), mean(sub_t209$cov80_12m)) * 1000 )),
          window_start   = "2022-01..2023-12",
          model          = c("Naive (RW)", "R ARIMA (réf. DM)", "R ETS", "Timestral-5M", "Timestral-209M"),
          arima_rmse     = round(c(sqrt(mean(e1_n^2)), sqrt(mean(e1_a^2)), sqrt(mean(e1_e^2)), sqrt(mean(sub_t5$err_h1^2)), sqrt(mean(sub_t209$err_h1^2))), 3),
          ets_rmse       = round(c(sqrt(mean(e12_n^2)), sqrt(mean(e12_a^2)), sqrt(mean(e12_e^2)), sqrt(mean(sub_t5$err_h12^2)), sqrt(mean(sub_t209$err_h12^2))), 3),
          t5m_rmse       = round(c(mean(r12_n), mean(r12_a), mean(r12_e), mean(sub_t5$rmse_12m), mean(sub_t209$rmse_12m)), 3),
          t209m_rmse     = round(c(0.0, mean(w12_a), mean(w12_e), mean(sub_t5$wis_12m), mean(sub_t209$wis_12m)), 3),
          dm_stat_h1     = round(c(dm_n_1["stat"], 0.0, dm_e_1["stat"], dm_t5_1["stat"], dm_t209_1["stat"]), 3),
          dm_pval_h1     = round(c(dm_n_1["pval"], 1.0, dm_e_1["pval"], dm_t5_1["pval"], dm_t209_1["pval"]), 4),
          dm_stat_h12    = round(c(dm_n_12["stat"], 0.0, dm_e_12["stat"], dm_t5_12["stat"], dm_t209_12["stat"]), 3),
          dm_pval_h12    = round(c(dm_n_12["pval"], 1.0, dm_e_12["pval"], dm_t5_12["pval"], dm_t209_12["pval"]), 4)
        )
      }

      rolling_and_ablation_metrics = rbind(ctx_df, do.call(rbind, roll_rows))
      rownames(rolling_and_ablation_metrics) <- NULL
      rolling_and_ablation_metrics
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      macro_timestral_5m: ^csv,
      macro_timestral_209m: ^csv,
      rolling_timestral: ^csv
    ],
    serializer = ^csv
  )

  ----------------------------------------------------------------------------
  -- STUDY 5: Comprehensive Quarto Report in French (Zero Hardcoded Literals)
  ----------------------------------------------------------------------------
  report = node(
    script = "src/report.qmd",
    runtime = Quarto,
    deps = [
      benchmark_metrics,
      cpi_probabilistic_metrics,
      retail_benchmark_metrics,
      retail_coherence_metrics,
      macro_benchmark_metrics,
      rolling_and_ablation_metrics
    ]
  )
}

-- Materialize and build
populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- Guard against failed pipeline nodes (AGENTS.md Rule 5):
-- 1. Check pipeline-wide diagnostics via errored_nodes(p)
err_list = errored_nodes(p) |> map(\(n) n.name)
check(expect_equal(length(err_list), 0))

-- 2. Verify all 20 expected nodes are present in the pipeline
expected_nodes = [
  "raw_data", "r_arima", "timestral_5m", "timestral_209m", "benchmark_metrics", "cpi_probabilistic_metrics",
  "retail_raw_data", "retail_r_arima", "retail_timestral_5m", "retail_timestral_209m", "retail_benchmark_metrics", "retail_coherence_metrics",
  "macro_raw_data", "macro_r_models", "macro_timestral_5m", "macro_timestral_209m", "macro_benchmark_metrics",
  "rolling_timestral", "rolling_and_ablation_metrics", "report"
]
check(expect_nodes(p, expected_nodes))

-- 3. Explicit node error guards (Rule 5)
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
if (is_error(p.retail_coherence_metrics)) { error(str_join(["Node 'retail_coherence_metrics' errored: ", error_msg(p.retail_coherence_metrics)])) }
if (is_error(p.macro_raw_data)) { error(str_join(["Node 'macro_raw_data' errored: ", error_msg(p.macro_raw_data)])) }
if (is_error(p.macro_r_models)) { error(str_join(["Node 'macro_r_models' errored: ", error_msg(p.macro_r_models)])) }
if (is_error(p.macro_timestral_5m)) { error(str_join(["Node 'macro_timestral_5m' errored: ", error_msg(p.macro_timestral_5m)])) }
if (is_error(p.macro_timestral_209m)) { error(str_join(["Node 'macro_timestral_209m' errored: ", error_msg(p.macro_timestral_209m)])) }
if (is_error(p.macro_benchmark_metrics)) { error(str_join(["Node 'macro_benchmark_metrics' errored: ", error_msg(p.macro_benchmark_metrics)])) }
if (is_error(p.rolling_timestral)) { error(str_join(["Node 'rolling_timestral' errored: ", error_msg(p.rolling_timestral)])) }
if (is_error(p.rolling_and_ablation_metrics)) { error(str_join(["Node 'rolling_and_ablation_metrics' errored: ", error_msg(p.rolling_and_ablation_metrics)])) }
if (is_error(p.report)) { error(str_join(["Node 'report' errored: ", error_msg(p.report)])) }

-- 4. Substantive data, coherence, and quantile-monotonicity assertions with check() (Rule 5)
cpi_metrics = read_node(p.benchmark_metrics)
check(expect_nrow(cpi_metrics, 7))
check(expect_no_na(cpi_metrics))

cpi_prob = read_node(p.cpi_probabilistic_metrics)
check(expect_nrow(cpi_prob, 5))
check(expect_no_na(cpi_prob))
-- Assert zero quantile crossings across all Study 1 probabilistic forecasts
check(expect_nrow(filter(cpi_prob, $crossings > 0), 0))

retail_metrics = read_node(p.retail_benchmark_metrics)
check(expect_nrow(retail_metrics, 7))
check(expect_no_na(retail_metrics))

retail_coh = read_node(p.retail_coherence_metrics)
check(expect_nrow(retail_coh, 12))
check(expect_no_na(retail_coh))
-- Assert hierarchical accounting coherence (< 1e-6) for all reconciled models (MinT-shrink & Bottom-Up)
check(expect_nrow(filter(retail_coh, $is_reconciled == 1 && $max_abs_incoherence >= 1e-6), 0))
-- Assert unreconciled base models are genuinely incoherent (> 100 M$)
check(expect_nrow(filter(retail_coh, $is_reconciled == 0 && $max_abs_incoherence < 100), 0))

macro_metrics = read_node(p.macro_benchmark_metrics)
check(expect_nrow(macro_metrics, 18))
-- Assert zero quantile crossings across all Study 3 probabilistic forecasts
check(expect_nrow(filter(macro_metrics, $crossings > 0), 0))

roll_tbl = read_node(p.rolling_timestral)
check(expect_nrow(roll_tbl, 96))
check(expect_no_na(roll_tbl))
-- Assert zero quantile crossings across all 96 rolling-origin Timestral forecasts (96 x 12 x 21 quantiles)
check(expect_nrow(filter(roll_tbl, $crossings > 0), 0))

roll_metrics = read_node(p.rolling_and_ablation_metrics)
check(expect_nrow(roll_metrics, 15))
check(expect_no_na(roll_metrics))

print("✓ timestral_demo: all 20 nodes and substantive coherence/monotonicity assertions passed successfully!")

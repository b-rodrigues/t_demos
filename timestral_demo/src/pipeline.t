-- timestral_demo: Multi-Study Methodological Benchmark of Timestral (5M & 209M)
-- vs Econometric Models (ARIMA, ETS, MinT-shrink, VAR, ARIMAX) with Probabilistic
-- Evaluation (WIS, CRPS, Pinball), Context-Length Ablation, and Spaced Rolling-Origin Diebold-Mariano Tests

p = pipeline {
  ----------------------------------------------------------------------------
  -- SHARED HELPERS & CODE DEPENDENCIES
  ----------------------------------------------------------------------------
  helpers = node(
    command = [code: read_file("src/helpers.R")],
    runtime = T,
    serializer = ^json
  )

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
      eval(parse(text = paste(helpers$code, collapse = "\n")))

      train_cpi = head(raw_data$cpi, -12)
      ts_train  = ts(train_cpi, frequency = 12)
      last_val  = tail(train_cpi, 1)

      # 1. Naive & Drift baselines with probabilistic quantiles
      fc_naive = rep(last_val, 12)
      q_naive  = forecast_quantiles("naive", h = 12, y_train = train_cpi)

      fc_drift = as.numeric(rwf(ts_train, h = 12, drift = TRUE)$mean)
      q_drift  = forecast_quantiles("drift", h = 12, y_train = train_cpi)

      # 2. Dynamic ARIMA with direct analytic Gaussian predictive quantiles
      fit_arima  = auto.arima(ts_train, seasonal = TRUE)
      fc_arima   = as.numeric(forecast(fit_arima, h = 12)$mean)
      q_arima    = forecast_quantiles(fit_arima, h = 12)
      arima_spec = paste0("ARIMA(", paste(arimaorder(fit_arima), collapse = ","), ")")

      # 3. State-Space Exponential Smoothing (ETS) with simulated state-space quantiles
      # (handles multiplicative error structures such as ETS(M,A,N) with exact simulated median & percentiles)
      fit_ets    = ets(ts_train)
      fc_ets     = as.numeric(forecast(fit_ets, h = 12)$mean)
      q_ets      = forecast_quantiles(fit_ets, h = 12, npaths = 3000, seed = 2024)
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
        out[[paste0("nai_", cn)]] = q_naive[, cn]
        out[[paste0("dri_", cn)]] = q_drift[, cn]
        out[[paste0("ari_", cn)]] = q_arima[, cn]
        out[[paste0("ets_", cn)]] = q_ets[, cn]
        out[[paste0("ens_", cn)]] = q_ens[, cn]
      }
      r_arima = out
    }>,
    deserializer = [
      raw_data: ^csv,
      helpers: ^json
    ],
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
      eval(parse(text = paste(helpers$code, collapse = "\n")))
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
      timestral_209m: ^csv,
      helpers: ^json
    ],
    serializer = ^csv
  )

  cpi_probabilistic_metrics = rn(
    command = <{
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(raw_data$cpi, 12)

      q_cols = quantile_cols(timestral_5m)
      stopifnot(check_grid(q_cols), identical(q_cols, quantile_cols(timestral_209m)))

      get_m <- function(df, prefix) {
        m = as.matrix(df[, paste0(prefix, q_cols)])
        colnames(m) = q_cols
        m
      }

      nai_q   = get_m(r_arima, "nai_")
      dri_q   = get_m(r_arima, "dri_")
      ari_q   = get_m(r_arima, "ari_")
      ets_q   = get_m(r_arima, "ets_")
      ens_q   = get_m(r_arima, "ens_")
      t5m_q   = as.matrix(timestral_5m[, q_cols])
      t209m_q = as.matrix(timestral_209m[, q_cols])

      ari_spec = as.character(r_arima$arima_spec[1])
      ets_spec = as.character(r_arima$ets_spec[1])

      sc_nai = summarise_scores(score_rows(actual, nai_q))
      sc_dri = summarise_scores(score_rows(actual, dri_q))
      sc_ari = summarise_scores(score_rows(actual, ari_q))
      sc_ets = summarise_scores(score_rows(actual, ets_q))
      sc_ens = summarise_scores(score_rows(actual, ens_q))
      sc_t5  = summarise_scores(score_rows(actual, t5m_q))
      sc_t20 = summarise_scores(score_rows(actual, t209m_q))

      nai_wis = sc_nai$wis[1]

      prob_list = list(
        cbind(data.frame(model = "Naive (Marche aléatoire)", dist_method = "RW gaussien (innovations 1-pas)", scaled_wis = 1.000), sc_nai),
        cbind(data.frame(model = "RW avec Dérive (Drift)",    dist_method = "RW+dérive gaussien",             scaled_wis = round(sc_dri$wis / nai_wis, 3)), sc_dri),
        cbind(data.frame(model = "R ARIMA",                  dist_method = paste0(ari_spec, " (analytique)"), scaled_wis = round(sc_ari$wis / nai_wis, 3)), sc_ari),
        cbind(data.frame(model = "R ETS",                    dist_method = paste0(ets_spec, " (simulé, B=3000)"), scaled_wis = round(sc_ets$wis / nai_wis, 3)), sc_ets),
        cbind(data.frame(model = "R Ensemble",               dist_method = "Moyenne de quantiles (ARIMA+ETS)", scaled_wis = round(sc_ens$wis / nai_wis, 3)), sc_ens),
        cbind(data.frame(model = "Timestral-5M",             dist_method = "21 quantiles natifs (L=168)",     scaled_wis = round(sc_t5$wis / nai_wis, 3)), sc_t5),
        cbind(data.frame(model = "Timestral-209M",           dist_method = "21 quantiles natifs (L=168)",     scaled_wis = round(sc_t20$wis / nai_wis, 3)), sc_t20)
      )

      cpi_probabilistic_metrics = do.call(rbind, prob_list)
      rownames(cpi_probabilistic_metrics) <- NULL
      cpi_probabilistic_metrics
    }>,
    deserializer = [
      raw_data: ^csv,
      r_arima: ^csv,
      timestral_5m: ^csv,
      timestral_209m: ^csv,
      helpers: ^json
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
      eval(parse(text = paste(helpers$code, collapse = "\n")))

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
        sc_e            = score_rows(act, forecast_quantiles(fit_e, h = 12, npaths = 2000, seed = 2024))
        wis_ets[s]      = mean(sc_e$wis)
        crps_ets[s]     = mean(sc_e$crps)

        fit_a = auto.arima(y_ts)
        fcasts_ari[[s]] = as.numeric(forecast(fit_a, h = 12)$mean)
        res_ari[[s]]    = as.numeric(residuals(fit_a, type = "response"))
        sc_a            = score_rows(act, forecast_quantiles(fit_a, h = 12))
        wis_ari[s]      = mean(sc_a$wis)
        crps_ari[s]     = mean(sc_a$crps)
      }

      # Correlation-standardized Schäfer-Strimmer (2005) MinT-shrink reconciliation
      # using in-sample 1-step residuals across all available training history
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
    deserializer = [
      retail_raw_data: ^csv,
      helpers: ^json
    ],
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

# 1. Programmatic assertion: verify batch evaluation matches individual 1D calls up to float32 precision (rtol=1e-5, atol=0.1)
mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
test_sample = mat_train[:, :120].copy()
batch_pred = fc.forecast(test_sample, prediction_length=1).median.cpu().numpy().squeeze()
indiv_pred = np.array([fc.forecast(test_sample[idx], prediction_length=1).median.cpu().numpy().squeeze() for idx in range(len(sectors_all))])
max_diff = float(np.max(np.abs(batch_pred - indiv_pred)))
assert np.allclose(batch_pred, indiv_pred, rtol=1e-5, atol=0.1), f"Batch vs 1D parity failed for Timestral-5M: max diff is {max_diff}"

# Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
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

# 1. Programmatic assertion: verify batch evaluation matches individual 1D calls up to float32 precision (rtol=1e-5, atol=0.1)
mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
test_sample = mat_train[:, :120].copy()
batch_pred = fc.forecast(test_sample, prediction_length=1).median.cpu().numpy().squeeze()
indiv_pred = np.array([fc.forecast(test_sample[idx], prediction_length=1).median.cpu().numpy().squeeze() for idx in range(len(sectors_all))])
max_diff = float(np.max(np.abs(batch_pred - indiv_pred)))
assert np.allclose(batch_pred, indiv_pred, rtol=1e-5, atol=0.1), f"Batch vs 1D parity failed for Timestral-209M: max diff is {max_diff}"

# Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
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
      eval(parse(text = paste(helpers$code, collapse = "\n")))
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
      retail_timestral_209m: ^csv,
      helpers: ^json
    ],
    serializer = ^csv
  )

  retail_coherence_metrics = rn(
    command = <{
      eval(parse(text = paste(helpers$code, collapse = "\n")))
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
      retail_timestral_209m: ^csv,
      helpers: ^json
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
      eval(parse(text = paste(helpers$code, collapse = "\n")))

      train = head(macro_raw_data, -12)
      test  = tail(macro_raw_data, 12)

      # 1. Naive baselines with probabilistic quantiles
      naive_cpi      = rep(tail(train$cpi, 1), 12)
      q_naive_cpi    = forecast_quantiles("naive", h = 12, y_train = train$cpi)

      naive_unrate   = rep(tail(train$unrate, 1), 12)
      q_naive_unrate = forecast_quantiles("naive", h = 12, y_train = train$unrate)

      # 2. Ex-ante Unconditional ARIMA & ETS with predictive quantiles
      ts_cpi    = ts(train$cpi, frequency = 12)
      ts_unrate = ts(train$unrate, frequency = 12)

      fit_cpi_arima    = auto.arima(ts_cpi)
      fc_cpi_arima     = as.numeric(forecast(fit_cpi_arima, h = 12)$mean)
      q_cpi_arima      = forecast_quantiles(fit_cpi_arima, h = 12)
      cpi_arima_spec   = paste0("ARIMA(", paste(arimaorder(fit_cpi_arima), collapse = ","), ")")

      fit_cpi_ets      = ets(ts_cpi)
      fc_cpi_ets       = as.numeric(forecast(fit_cpi_ets, h = 12)$mean)
      q_cpi_ets        = forecast_quantiles(fit_cpi_ets, h = 12, npaths = 3000, seed = 2024)
      cpi_ets_spec     = fit_cpi_ets$method

      fit_unrate_arima  = auto.arima(ts_unrate)
      fc_unrate_arima   = as.numeric(forecast(fit_unrate_arima, h = 12)$mean)
      q_unrate_arima    = forecast_quantiles(fit_unrate_arima, h = 12)
      unrate_arima_spec = paste0("ARIMA(", paste(arimaorder(fit_unrate_arima), collapse = ","), ")")

      fit_unrate_ets    = ets(ts_unrate)
      fc_unrate_ets     = as.numeric(forecast(fit_unrate_ets, h = 12)$mean)
      q_unrate_ets      = forecast_quantiles(fit_unrate_ets, h = 12, npaths = 3000, seed = 2024)
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
      q_cpi_arimax      = forecast_quantiles(fit_cpi_arimax, h = 12, xreg = test$fedfunds)
      cpi_arimax_spec   = paste0("ARIMAX(", paste(arimaorder(fit_cpi_arimax), collapse = ","), ")")

      fit_unrate_arimax  = auto.arima(ts_unrate, xreg = train$fedfunds)
      fc_unrate_arimax   = as.numeric(forecast(fit_unrate_arimax, xreg = test$fedfunds, h = 12)$mean)
      q_unrate_arimax    = forecast_quantiles(fit_unrate_arimax, h = 12, xreg = test$fedfunds)
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
        out[[paste0("cpi_nai_", cn)]]    = q_naive_cpi[, cn]
        out[[paste0("cpi_ari_", cn)]]    = q_cpi_arima[, cn]
        out[[paste0("cpi_ets_", cn)]]    = q_cpi_ets[, cn]
        out[[paste0("cpi_arx_", cn)]]    = q_cpi_arimax[, cn]
        out[[paste0("unr_nai_", cn)]]    = q_naive_unrate[, cn]
        out[[paste0("unr_ari_", cn)]]    = q_unrate_arima[, cn]
        out[[paste0("unr_ets_", cn)]]    = q_unrate_ets[, cn]
        out[[paste0("unr_arx_", cn)]]    = q_unrate_arimax[, cn]
      }
      macro_r_models = out
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      helpers: ^json
    ],
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
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(macro_raw_data, 12)
      q_cols = q_names()

      get_q <- function(df, prefix) {
        m = as.matrix(df[, paste0(prefix, q_cols)])
        colnames(m) = q_cols
        m
      }

      var_p   = macro_r_models$var_lag[1]
      var_lbl = paste0("VAR(p=", var_p, ", AIC)")

      act_c = actual$cpi
      n_c   = rmse(macro_r_models$naive_cpi, act_c)
      q_nc  = get_q(macro_r_models, "cpi_nai_")
      sc_nc = summarise_scores(score_rows(act_c, q_nc), digits = 3)
      n_wis_c = sc_nc$wis[1]

      act_u = actual$unrate
      n_u   = rmse(macro_r_models$naive_unrate, act_u)
      q_nu  = get_q(macro_r_models, "unr_nai_")
      sc_nu = summarise_scores(score_rows(act_u, q_nu), digits = 3)
      n_wis_u = sc_nu$wis[1]

      build_row <- function(target_lbl, act, n_rmse, n_wis, regime_lbl, mod_lbl, spec_lbl, pred, qmat = NULL) {
        r_val = rmse(pred, act)
        if (is.null(qmat)) {
          sc = data.frame(scaled_wis = NA_real_, wis = NA_real_, crps = NA_real_, mean_pinball = NA_real_,
                          coverage_80 = NA_real_, coverage_90 = NA_real_, width_80 = NA_real_, width_90 = NA_real_, crossings = 0L)
        } else {
          sc_val = summarise_scores(score_rows(act, qmat), digits = 3)
          s_wis  = if (is.na(n_wis) || n_wis == 0) NA_real_ else round(sc_val$wis / n_wis, 3)
          sc     = cbind(data.frame(scaled_wis = s_wis), sc_val)
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

      rows = list(
        # CPI
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_cpi, q_nc),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$cpi_arima_spec[1]), macro_r_models$arima_cpi, get_q(macro_r_models, "cpi_ari_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$cpi_ets_spec[1]), macro_r_models$ets_cpi, get_q(macro_r_models, "cpi_ets_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_cpi, NULL),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_cpi_univ, get_q(macro_timestral_5m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_cpi_univ, get_q(macro_timestral_209m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$cpi_arimax_spec[1]), macro_r_models$arimax_cpi, get_q(macro_r_models, "cpi_arx_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_cpi_cov, get_q(macro_timestral_5m, "cpi_c_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_cpi_cov, get_q(macro_timestral_209m, "cpi_c_")),
        # UNRATE
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_unrate, q_nu),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$unrate_arima_spec[1]), macro_r_models$arima_unrate, get_q(macro_r_models, "unr_ari_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$unrate_ets_spec[1]), macro_r_models$ets_unrate, get_q(macro_r_models, "unr_ets_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_unrate, NULL),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_unrate_univ, get_q(macro_timestral_5m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_unrate_univ, get_q(macro_timestral_209m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$unrate_arimax_spec[1]), macro_r_models$arimax_unrate, get_q(macro_r_models, "unr_arx_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_unrate_cov, get_q(macro_timestral_5m, "unr_c_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_unrate_cov, get_q(macro_timestral_209m, "unr_c_"))
      )

      macro_benchmark_metrics = do.call(rbind, rows)
      rownames(macro_benchmark_metrics) <- NULL
      macro_benchmark_metrics
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      macro_r_models: ^csv,
      macro_timestral_5m: ^csv,
      macro_timestral_209m: ^csv,
      helpers: ^json
    ],
    serializer = ^csv
  )

  ----------------------------------------------------------------------------
  -- STUDY 4: Multi-Origin Rolling Evaluation (24 Spaced Origins) & Diebold-Mariano
  -- Tests (Harvey Small-Sample Correction) + Context-Length Ablation
  ----------------------------------------------------------------------------
  rolling_timestral = pyn(
    command = <{
import pandas as pd
import numpy as np
from timestral import TimestralForecaster

N = len(macro_raw_data)  # 300
all_dates = pd.date_range("2000-01-01", periods=300, freq="MS").strftime("%Y-%m").tolist()

# 24 origins spaced every 6 months across 2012-2023 (ending at L=288, test 2024):
# L in [150, 156, ..., 282, 288]
origins = [288 - (23 - i) * 6 for i in range(24)]

fc5   = TimestralForecaster.from_pretrained("models/Timestral-5M")
fc209 = TimestralForecaster.from_pretrained("models/Timestral-209M")

rows = []
for v in ["cpi", "unrate"]:
    y = macro_raw_data[v].values
    for idx, L in enumerate(origins):
        ctx = y[:L].copy()
        act = y[L : L + 12]
        w_start = all_dates[L]
        w_end = all_dates[L + 11]
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
                "test_window": f"{w_start}..{w_end}",
                "model": mname,
                "err_h1": float(act[0] - med[0]),
                "err_h12": float(act[11] - med[11]),
                "rmse_12m": float(np.sqrt(np.mean((act - med) ** 2))),
                "mae_12m": float(np.mean(np.abs(act - med))),
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

  context_ablation_metrics = rn(
    command = <{
      library(forecast)
      eval(parse(text = paste(helpers$code, collapse = "\n")))

      all_dates = format(seq(as.Date("2000-01-01"), by = "month", length.out = 300), "%Y-%m")
      train_cpi = head(macro_raw_data$cpi, 288)
      test_cpi  = tail(macro_raw_data$cpi, 12)
      L_grid    = c(60, 120, 168, 240, 288)

      ctx_rows = lapply(L_grid, function(L) {
        sub_y      = tail(train_cpi, L)
        start_date = all_dates[288 - L + 1]
        ts_sub     = ts(sub_y, frequency = 12)
        fit_a      = auto.arima(ts_sub)
        fc_a       = as.numeric(forecast(fit_a, h = 12)$mean)
        fit_e      = ets(ts_sub)
        fc_e       = as.numeric(forecast(fit_e, h = 12)$mean)
        p5         = macro_timestral_5m[[paste0("ctx_", L, "_med")]]
        p209       = macro_timestral_209m[[paste0("ctx_", L, "_med")]]
        data.frame(
          context_months = L,
          window_start   = start_date,
          arima_spec     = paste0("ARIMA(", paste(arimaorder(fit_a), collapse = ","), ")"),
          ets_spec       = fit_e$method,
          arima_rmse     = round(rmse(fc_a, test_cpi), 4),
          ets_rmse       = round(rmse(fc_e, test_cpi), 4),
          t5m_rmse       = round(rmse(p5, test_cpi), 4),
          t209m_rmse     = round(rmse(p209, test_cpi), 4)
        )
      })
      context_ablation_metrics = do.call(rbind, ctx_rows)
      rownames(context_ablation_metrics) <- NULL
      context_ablation_metrics
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      macro_timestral_5m: ^csv,
      macro_timestral_209m: ^csv,
      helpers: ^json
    ],
    serializer = ^csv
  )

  rolling_origin_metrics = rn(
    command = <{
      library(forecast)
      eval(parse(text = paste(helpers$code, collapse = "\n")))

      origins = seq(150, 288, by = 6) # 24 origins spaced by 6 months
      covid_origins = c(234, 240, 246, 252) # Origins whose 12-month test windows cover COVID 2020-2021
      idx_nocov = which(!origins %in% covid_origins)

      roll_rows = list()
      for (v in c("cpi", "unrate")) {
        y = macro_raw_data[[v]]
        t_lbl = if (v == "cpi") "CPI (24 origines)" else "UNRATE (24 origines)"

        e1_n = e12_n = r12_n = m12_n = w12_n = crps12_n = c80_n = numeric(length(origins))
        e1_a = e12_a = r12_a = m12_a = w12_a = crps12_a = c80_a = numeric(length(origins))
        e1_e = e12_e = r12_e = m12_e = w12_e = crps12_e = c80_e = numeric(length(origins))

        for (i in seq_along(origins)) {
          L = origins[i]
          tr = ts(y[1:L], frequency = 12)
          act = y[(L + 1):(L + 12)]

          # Naive with robust probabilistic quantiles
          p_n = rep(y[L], 12)
          q_n = forecast_quantiles("naive", h = 12, y_train = y[1:L])
          sc_n = score_rows(act, q_n)
          e1_n[i] = act[1] - p_n[1]; e12_n[i] = act[12] - p_n[12]
          r12_n[i] = rmse(p_n, act); m12_n[i] = mae(p_n, act)
          w12_n[i] = mean(sc_n$wis); crps12_n[i] = mean(sc_n$crps); c80_n[i] = mean(sc_n$in80)

          # ARIMA (consistent specification)
          fit_a = auto.arima(tr)
          p_a   = as.numeric(forecast(fit_a, h = 12)$mean)
          sc_a  = score_rows(act, forecast_quantiles(fit_a, h = 12))
          e1_a[i] = act[1] - p_a[1]; e12_a[i] = act[12] - p_a[12]
          r12_a[i] = rmse(p_a, act); m12_a[i] = mae(p_a, act)
          w12_a[i] = mean(sc_a$wis); crps12_a[i] = mean(sc_a$crps); c80_a[i] = mean(sc_a$in80)

          # ETS (consistent specification with state-space simulations)
          fit_e = ets(tr)
          p_e   = as.numeric(forecast(fit_e, h = 12)$mean)
          sc_e  = score_rows(act, forecast_quantiles(fit_e, h = 12, npaths = 1000, seed = 2024 + i))
          e1_e[i] = act[1] - p_e[1]; e12_e[i] = act[12] - p_e[12]
          r12_e[i] = rmse(p_e, act); m12_e[i] = mae(p_e, act)
          w12_e[i] = mean(sc_e$wis); crps12_e[i] = mean(sc_e$crps); c80_e[i] = mean(sc_e$in80)
        }

        sub_t5   = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-5M", ]
        sub_t209 = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-209M", ]
        sub_t5   = sub_t5[order(sub_t5$origin_idx), ]
        sub_t209 = sub_t209[order(sub_t209$origin_idx), ]

        # DM tests vs ARIMA benchmark:
        # h=1: independent 1-step errors spaced by 6 months -> h = 1
        # h=12: 12-step errors sampled every 6 months overlap by 6 months -> effective autocorrelation lag ceil(12/6) = 2 -> h = 2
        dm_n_1    = dm_harvey(e1_n, e1_a, h = 1);             dm_n_12    = dm_harvey(e12_n, e12_a, h = 2)
        dm_e_1    = dm_harvey(e1_e, e1_a, h = 1);             dm_e_12    = dm_harvey(e12_e, e12_a, h = 2)
        dm_t5_1   = dm_harvey(sub_t5$err_h1, e1_a, h = 1);    dm_t5_12   = dm_harvey(sub_t5$err_h12, e12_a, h = 2)
        dm_t209_1 = dm_harvey(sub_t209$err_h1, e1_a, h = 1);  dm_t209_12 = dm_harvey(sub_t209$err_h12, e12_a, h = 2)

        models_vec = c("Naive (RW)", "R ARIMA (réf. DM)", "R ETS", "Timestral-5M", "Timestral-209M")

        # 1. Horizon Pas 1 (h=1)
        df_h1 = data.frame(
          target        = t_lbl,
          horizon       = "Pas 1 (h=1)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(e1_n^2)), sqrt(mean(e1_a^2)), sqrt(mean(e1_e^2)), sqrt(mean(sub_t5$err_h1^2)), sqrt(mean(sub_t209$err_h1^2))), 3),
          mae           = round(c(mean(abs(e1_n)), mean(abs(e1_a)), mean(abs(e1_e)), mean(abs(sub_t5$err_h1)), mean(abs(sub_t209$err_h1))), 3),
          rmse_ex_covid = round(c(sqrt(mean(e1_n[idx_nocov]^2)), sqrt(mean(e1_a[idx_nocov]^2)), sqrt(mean(e1_e[idx_nocov]^2)), sqrt(mean(sub_t5$err_h1[idx_nocov]^2)), sqrt(mean(sub_t209$err_h1[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(abs(e1_n[idx_nocov])), mean(abs(e1_a[idx_nocov])), mean(abs(e1_e[idx_nocov])), mean(abs(sub_t5$err_h1[idx_nocov])), mean(abs(sub_t209$err_h1[idx_nocov]))), 3),
          wis           = NA_real_,
          crps          = NA_real_,
          coverage_80   = NA_real_,
          dm_stat       = c(round(dm_n_1["stat"], 3), NA_real_, round(dm_e_1["stat"], 3), round(dm_t5_1["stat"], 3), round(dm_t209_1["stat"], 3)),
          dm_pval       = c(round(dm_n_1["pval"], 4), NA_real_, round(dm_e_1["pval"], 4), round(dm_t5_1["pval"], 4), round(dm_t209_1["pval"], 4))
        )

        # 2. Horizon Pas 12 (h=12)
        df_h12 = data.frame(
          target        = t_lbl,
          horizon       = "Pas 12 (h=12)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(e12_n^2)), sqrt(mean(e12_a^2)), sqrt(mean(e12_e^2)), sqrt(mean(sub_t5$err_h12^2)), sqrt(mean(sub_t209$err_h12^2))), 3),
          mae           = round(c(mean(abs(e12_n)), mean(abs(e12_a)), mean(abs(e12_e)), mean(abs(sub_t5$err_h12)), mean(abs(sub_t209$err_h12))), 3),
          rmse_ex_covid = round(c(sqrt(mean(e12_n[idx_nocov]^2)), sqrt(mean(e12_a[idx_nocov]^2)), sqrt(mean(e12_e[idx_nocov]^2)), sqrt(mean(sub_t5$err_h12[idx_nocov]^2)), sqrt(mean(sub_t209$err_h12[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(abs(e12_n[idx_nocov])), mean(abs(e12_a[idx_nocov])), mean(abs(e12_e[idx_nocov])), mean(abs(sub_t5$err_h12[idx_nocov])), mean(abs(sub_t209$err_h12[idx_nocov]))), 3),
          wis           = NA_real_,
          crps          = NA_real_,
          coverage_80   = NA_real_,
          dm_stat       = c(round(dm_n_12["stat"], 3), NA_real_, round(dm_e_12["stat"], 3), round(dm_t5_12["stat"], 3), round(dm_t209_12["stat"], 3)),
          dm_pval       = c(round(dm_n_12["pval"], 4), NA_real_, round(dm_e_12["pval"], 4), round(dm_t5_12["pval"], 4), round(dm_t209_12["pval"], 4))
        )

        # 3. Horizon Trajectoire (1..12m)
        df_traj = data.frame(
          target        = t_lbl,
          horizon       = "Trajectoire (1..12m)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(r12_n^2)), sqrt(mean(r12_a^2)), sqrt(mean(r12_e^2)), sqrt(mean(sub_t5$rmse_12m^2)), sqrt(mean(sub_t209$rmse_12m^2))), 3),
          mae           = round(c(mean(m12_n), mean(m12_a), mean(m12_e), mean(sub_t5$mae_12m), mean(sub_t209$mae_12m)), 3),
          rmse_ex_covid = round(c(sqrt(mean(r12_n[idx_nocov]^2)), sqrt(mean(r12_a[idx_nocov]^2)), sqrt(mean(r12_e[idx_nocov]^2)), sqrt(mean(sub_t5$rmse_12m[idx_nocov]^2)), sqrt(mean(sub_t209$rmse_12m[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(m12_n[idx_nocov]), mean(m12_a[idx_nocov]), mean(m12_e[idx_nocov]), mean(sub_t5$mae_12m[idx_nocov]), mean(sub_t209$mae_12m[idx_nocov])), 3),
          wis           = round(c(mean(w12_n), mean(w12_a), mean(w12_e), mean(sub_t5$wis_12m), mean(sub_t209$wis_12m)), 3),
          crps          = round(c(mean(crps12_n), mean(crps12_a), mean(crps12_e), mean(sub_t5$crps_12m), mean(sub_t209$crps_12m)), 3),
          coverage_80   = round(c(mean(c80_n), mean(c80_a), mean(c80_e), mean(sub_t5$cov80_12m), mean(sub_t209$cov80_12m)), 3),
          dm_stat       = NA_real_,
          dm_pval       = NA_real_
        )

        roll_rows[[paste0(v, "_h1")]]   = df_h1
        roll_rows[[paste0(v, "_h12")]]  = df_h12
        roll_rows[[paste0(v, "_traj")]] = df_traj
      }

      rolling_origin_metrics = do.call(rbind, roll_rows)
      rownames(rolling_origin_metrics) <- NULL
      rolling_origin_metrics
    }>,
    deserializer = [
      macro_raw_data: ^csv,
      rolling_timestral: ^csv,
      helpers: ^json
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
      context_ablation_metrics,
      rolling_origin_metrics
    ]
  )
}

-- Materialize and build
populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()

-- Guard against failed pipeline nodes (AGENTS.md Rule 5)
err_list = errored_nodes(p) |> map(\(n) n.name)
if (length(err_list) > 0) {
  error(str_join(["Pipeline nodes errored: ", str_join(err_list, ", ")]))
}
check(expect_equal(length(err_list), 0))

-- Verify all 22 expected nodes are present in the pipeline
expected_nodes = [
  "helpers",
  "raw_data", "r_arima", "timestral_5m", "timestral_209m", "benchmark_metrics", "cpi_probabilistic_metrics",
  "retail_raw_data", "retail_r_arima", "retail_timestral_5m", "retail_timestral_209m", "retail_benchmark_metrics", "retail_coherence_metrics",
  "macro_raw_data", "macro_r_models", "macro_timestral_5m", "macro_timestral_209m", "macro_benchmark_metrics",
  "rolling_timestral", "context_ablation_metrics", "rolling_origin_metrics", "report"
]
check(expect_nodes(p, expected_nodes))

-- Data integrity assertion: verify that the last 180 observations of macro CPI match cpi.csv exactly
cpi_hist = read_node(p.raw_data).cpi
macro_cpi = read_node(p.macro_raw_data).cpi
check(expect_equal(tail(macro_cpi, 180), cpi_hist))

-- Substantive data, coherence, and quantile assertions
cpi_metrics = read_node(p.benchmark_metrics)
check(expect_nrow(cpi_metrics, 7))
check(expect_no_na(cpi_metrics))

cpi_prob = read_node(p.cpi_probabilistic_metrics)
check(expect_nrow(cpi_prob, 7))
check(expect_no_na(cpi_prob))
-- Assert zero quantile crossings across all Study 1 probabilistic forecasts
check(expect_nrow(filter(cpi_prob, $crossings > 0), 0))

retail_metrics = read_node(p.retail_benchmark_metrics)
check(expect_nrow(retail_metrics, 7))
check(expect_no_na(retail_metrics))

retail_coh = read_node(p.retail_coherence_metrics)
check(expect_nrow(retail_coh, 12))
check(expect_no_na(retail_coh))
-- Assert relative accounting coherence (< 1e-8 * max_scale ~ 7.5e-3 M$) for all reconciled models
check(expect_nrow(filter(retail_coh, $is_reconciled == 1 && $max_abs_incoherence >= 1e-8 * 750000), 0))
-- Scale-invariant coherence check: minimum base incoherence is at least 1,000x larger than maximum reconciled incoherence
min_base_incoh = min(filter(retail_coh, $is_reconciled == 0).max_abs_incoherence)
max_rec_incoh  = max(filter(retail_coh, $is_reconciled == 1).max_abs_incoherence)
check(expect_true(min_base_incoh > 1000 * max_rec_incoh))

macro_metrics = read_node(p.macro_benchmark_metrics)
check(expect_nrow(macro_metrics, 18))
-- Assert zero quantile crossings across all Study 3 probabilistic forecasts
check(expect_nrow(filter(macro_metrics, $crossings > 0), 0))

roll_tbl = read_node(p.rolling_timestral)
check(expect_nrow(roll_tbl, 96))
check(expect_no_na(roll_tbl))
-- Assert zero quantile crossings across all 96 rolling-origin Timestral forecasts (96 x 12 x 21 quantiles)
check(expect_nrow(filter(roll_tbl, $crossings > 0), 0))

ablation_metrics = read_node(p.context_ablation_metrics)
check(expect_nrow(ablation_metrics, 5))
check(expect_no_na(ablation_metrics))

-- Non-regression assertion: Ablation at L=168 must reproduce Study 1 benchmark metrics (< 1e-3)
abl_ari = min(filter(ablation_metrics, $context_months == 168).arima_rmse)
abl_ets = min(filter(ablation_metrics, $context_months == 168).ets_rmse)
abl_t5m = min(filter(ablation_metrics, $context_months == 168).t5m_rmse)
abl_t20 = min(filter(ablation_metrics, $context_months == 168).t209m_rmse)

s1_ari = min(filter(cpi_metrics, $model == "R ARIMA (AIC)").rmse)
s1_ets = min(filter(cpi_metrics, $model == "R ETS (Espace d'états)").rmse)
s1_t5m = min(filter(cpi_metrics, $model == "Timestral-5M (Zero-shot)").rmse)
s1_t20 = min(filter(cpi_metrics, $model == "Timestral-209M (Zero-shot)").rmse)

check(expect_true(abs(abl_ari - s1_ari) < 0.001))
check(expect_true(abs(abl_ets - s1_ets) < 0.001))
check(expect_true(abs(abl_t5m - s1_t5m) < 0.001))
check(expect_true(abs(abl_t20 - s1_t20) < 0.001))

roll_metrics = read_node(p.rolling_origin_metrics)
check(expect_nrow(roll_metrics, 30))
-- Assert no NA values in point error metrics across all 30 rolling origin evaluation rows
check(expect_nrow(filter(roll_metrics, is_na($rmse) || is_na($mae) || is_na($rmse_ex_covid) || is_na($mae_ex_covid)), 0))

print("✓ timestral_demo: all 22 nodes, non-regression, and substantive coherence/monotonicity assertions passed successfully!")

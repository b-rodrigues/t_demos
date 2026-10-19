# Shared helpers for the R nodes of timestral_demo (sourced inside each node sandbox).

# Expected 21-quantile grid of Timestral (verified against Forecast.quantile_levels).
Q_LEVELS <- c(0.01, seq(0.05, 0.95, by = 0.05), 0.99)
q_names  <- function(lv = Q_LEVELS) sprintf("q_%02d", round(lv * 100))

# Extract quantile columns and parse their probability levels dynamically from column names.
quantile_cols    <- function(df) grep("^q_[0-9]{2}$", names(df), value = TRUE)
levels_from_cols <- function(cols) as.integer(sub("^q_", "", cols)) / 100
check_grid       <- function(cols) isTRUE(all.equal(levels_from_cols(cols), Q_LEVELS))

# Predictive quantiles directly from forecast::forecast(..., level = ...) with state-space
# trajectory simulation for ETS (which selects multiplicative error models ETS(M,A,N) / ETS(M,Ad,N)
# whose prediction intervals are asymmetric).
forecast_quantiles <- function(fit, h = 12, xreg = NULL, simulate = inherits(fit, "ets"), npaths = 5000, seed = 2024) {
  set.seed(seed)
  lv <- c(10, 20, 30, 40, 50, 60, 70, 80, 90, 98)
  fc <- if (is.null(xreg)) {
    forecast(fit, h = h, level = lv, simulate = simulate, npaths = npaths)
  } else {
    forecast(fit, h = h, xreg = xreg, level = lv, simulate = simulate, npaths = npaths)
  }
  expected_colnames <- paste0(lv, "%")
  stopifnot(
    identical(as.numeric(fc$level), lv),
    identical(colnames(fc$lower), expected_colnames),
    identical(colnames(fc$upper), expected_colnames)
  )
  lo_mat <- matrix(as.numeric(fc$lower), nrow = h, ncol = length(lv), dimnames = list(NULL, colnames(fc$lower)))
  hi_mat <- matrix(as.numeric(fc$upper), nrow = h, ncol = length(lv), dimnames = list(NULL, colnames(fc$upper)))
  lo <- lo_mat[, rev(expected_colnames), drop = FALSE]
  hi <- hi_mat[, expected_colnames, drop = FALSE]
  md <- matrix(as.numeric(fc$mean), nrow = h, ncol = 1)
  qmat <- cbind(lo, md, hi)
  tau <- c((1 - rev(lv) / 100) / 2, 0.50, (1 + lv / 100) / 2)
  # Isotonic rearrangement (Chernozhukov, Fernández-Val & Galichon, 2010)
  qmat <- t(apply(qmat, 1, sort))
  colnames(qmat) <- sprintf("q_%02d", round(tau * 100))
  qmat
}

pinball <- function(y, q, tau) ifelse(y >= q, tau * (y - q), (1 - tau) * (q - y))

# Probabilistic scores from an n x 21 quantile matrix indexed by column name:
#  - wis: Weighted Interval Score (Bracher et al., 2021) = (2 / (2K + 1)) * sum_k pinball_k
#  - crps: Riemann cell-weighted integral of 2 * pinball_k over [0, 1] (proper tail weighting)
#  - mean_pinball: unweighted mean pinball loss across the 21 quantiles
#  - in80, in90: coverage indicators using named columns q_10, q_90, q_05, q_95
#  - w80, w90: interval widths (q_90 - q_10) and (q_95 - q_05)
#  - cross: number of non-monotonic quantile inversions per row
score_rows <- function(y, qmat) {
  cols <- colnames(qmat)
  stopifnot(check_grid(cols))
  tau <- levels_from_cols(cols)
  L <- sapply(seq_along(tau), function(k) pinball(y, qmat[, cols[k]], tau[k]))
  L <- matrix(L, nrow = length(y))
  K <- (length(tau) - 1) / 2
  bounds <- c(0, (head(tau, -1) + tail(tau, -1)) / 2, 1)
  weights_crps <- diff(bounds)
  data.frame(
    wis          = rowSums(L) / (K + 0.5),
    crps         = 2 * as.numeric(L %*% weights_crps),
    mean_pinball = rowMeans(L),
    in80         = as.numeric(y >= qmat[, "q_10"] & y <= qmat[, "q_90"]),
    in90         = as.numeric(y >= qmat[, "q_05"] & y <= qmat[, "q_95"]),
    w80          = as.numeric(qmat[, "q_90"] - qmat[, "q_10"]),
    w90          = as.numeric(qmat[, "q_95"] - qmat[, "q_05"]),
    cross        = apply(qmat, 1, function(r) sum(diff(r) < -1e-9))
  )
}

summarise_scores <- function(sc, digits = 4) {
  data.frame(
    wis          = round(mean(sc$wis), digits),
    crps         = round(mean(sc$crps), digits),
    mean_pinball = round(mean(sc$mean_pinball), digits),
    coverage_80  = round(mean(sc$in80), 3),
    coverage_90  = round(mean(sc$in90), 3),
    width_80     = round(mean(sc$w80), 2),
    width_90     = round(mean(sc$w90), 2),
    crossings    = as.integer(sum(sc$cross))
  )
}

rmse <- function(pred, act) sqrt(mean((pred - act)^2))
mae  <- function(pred, act) mean(abs(pred - act))

# Correlation-standardized Schäfer & Strimmer (2005) shrinkage estimator towards diagonal target
# (identical to hts:::shrink.estim used by MinT-shrink in Wickramasuriya et al., 2019).
shrink_cov <- function(res) {
  n <- nrow(res)
  covm <- crossprod(res) / n
  tar <- diag(diag(covm))
  corm <- cov2cor(covm)
  xs <- scale(res, center = FALSE, scale = sqrt(diag(covm)))
  v <- (1 / (n * (n - 1))) * (crossprod(xs^2) - (crossprod(xs)^2) / n)
  diag(v) <- 0
  d <- (corm - diag(nrow(corm)))^2
  lambda <- max(min(sum(v) / sum(d), 1), 0)
  list(W = lambda * tar + (1 - lambda) * covm, lambda = lambda)
}

# MinT projection: y_tilde = S P y_hat, P = (S' W^-1 S)^-1 S' W^-1
mint <- function(base, W, S) {
  Wi <- solve(W)
  P <- solve(t(S) %*% Wi %*% S, t(S) %*% Wi)
  rec <- t(S %*% P %*% t(base))
  colnames(rec) <- colnames(base)
  coh_err <- max(abs(rec[, 1] - rowSums(rec[, -1, drop = FALSE])))
  list(rec = rec, coh_err = coh_err)
}

# Diebold-Mariano test with Harvey, Leybourne & Newbold (1997) small-sample correction
# and Bartlett long-run variance estimator.
dm_harvey <- function(e_model, e_bench, h = 1) {
  if (all(abs(e_model - e_bench) < 1e-12)) {
    return(c(stat = 0.0, pval = 1.0))
  }
  res <- tryCatch(
    forecast::dm.test(e_model, e_bench, alternative = "two.sided", h = h, power = 2, varestimator = "bartlett"),
    error = function(e) list(statistic = 0.0, p.value = 1.0)
  )
  st <- as.numeric(res$statistic)
  pv <- as.numeric(res$p.value)
  if (is.na(st) || is.nan(st)) st <- 0.0
  if (is.na(pv) || is.nan(pv)) pv <- 1.0
  c(stat = st, pval = pv)
}

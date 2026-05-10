import base
import dataframe
import colcraft
import stats
import math

p = pipeline {
    stats_data = node(
        command = <{
            to_dataframe([
                [id: 1, group: "A", category: "apple",  value: 1.2, value_with_na: 1.2, basis_x: 1.0, feature_a: 2.0, feature_b: 1.0, response: 7.50, actual: 0.9, predicted: 1.1, success: 0],
                [id: 2, group: "A", category: "apple",  value: 2.5, value_with_na: 2.5, basis_x: 2.0, feature_a: 3.8, feature_b: 1.6, response: 10.20, actual: 1.8, predicted: 1.7, success: 0],
                [id: 3, group: "B", category: "banana", value: 3.1, value_with_na: 3.1, basis_x: 3.0, feature_a: 4.1, feature_b: 2.1, response: 11.00, actual: 3.2, predicted: 3.0, success: 0],
                [id: 4, group: "B", category: "cherry", value: 4.8, value_with_na: na_float(), basis_x: 4.0, feature_a: 5.9, feature_b: 2.8, response: 13.90, actual: 4.1, predicted: 4.4, success: 1],
                [id: 5, group: "C", category: "cherry", value: 5.2, value_with_na: 5.2, basis_x: 5.0, feature_a: 6.4, feature_b: 1.4, response: 16.00, actual: 5.4, predicted: 5.0, success: 1],
                [id: 6, group: "C", category: "apple",  value: 6.4, value_with_na: 6.4, basis_x: 6.0, feature_a: 7.1, feature_b: 2.3, response: 18.20, actual: 6.8, predicted: 6.9, success: 1],
                [id: 7, group: "A", category: "banana", value: 7.1, value_with_na: 7.1, basis_x: 7.0, feature_a: 8.7, feature_b: 2.9, response: 20.00, actual: 7.5, predicted: 7.2, success: 1],
                [id: 8, group: "B", category: "banana", value: 8.3, value_with_na: 8.3, basis_x: 8.0, feature_a: 9.2, feature_b: 3.2, response: 21.90, actual: 8.6, predicted: 8.4, success: 1]
            ])
        }>,
        runtime = T,
        serializer = ^arrow
    )

    counts_t = node(
        stats_data,
        command = <{
            stats_data
                |> group_by($group)
                |> summarize(rows = n(), unique_categories = n_distinct($category))
                |> arrange($group)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    counts_r = node(
        stats_data,
        command = <{
            library(dplyr)
            stats_data %>%
                group_by(group) %>%
                summarize(rows = n(), unique_categories = n_distinct(category), .groups = "drop") %>%
                arrange(group)
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    descriptive_t = node(
        stats_data,
        command = <{
            round_scalar = \(x) {
                if (is_error(x)) { x } else if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            }

            round_values = \(xs) { xs }

            clean_values = pull(stats_data, $value)
            values_with_na = pull(stats_data, $value_with_na)
            basis_values = pull(stats_data, $basis_x)
            actuals = pull(stats_data, $actual)
            preds = pull(stats_data, $predicted)
            residuals_vec = actuals .- preds

            -- Workaround for na_rm arity issues in current runtime
            clean_from_na = get(values_with_na, filter_lens(\(x) !is_na(x)))

            [
                mean: round_scalar(mean(clean_from_na)),
                median: round_scalar(median(clean_from_na)),
                min: round_scalar(min(clean_from_na)),
                max: round_scalar(max(clean_from_na)),
                range: round_values(range(clean_from_na)),
                var: round_scalar(var(clean_from_na)),
                sd: round_scalar(sd(clean_from_na)),
                iqr: round_scalar(iqr(clean_from_na)),
                mad: round_scalar(mad(clean_values)),
                fivenum: round_values(fivenum(clean_values)),
                quantile: [
                    round_scalar(quantile(clean_from_na, 0.25)),
                    round_scalar(quantile(clean_from_na, 0.5)),
                    round_scalar(quantile(clean_from_na, 0.75))
                ],
                skewness: round_scalar(skewness(clean_values)),
                kurtosis: round_scalar(kurtosis(clean_values)),
                trimmed_mean: round_scalar(trimmed_mean(clean_from_na, 0.125)),
                winsorize: round_values(winsorize(clean_values, [0.2, 0.2])),
                cv: round_scalar(cv(clean_values)),
                normalize: round_values(normalize(clean_values)),
                standardize: round_values(standardize(clean_values)),
                scale: round_values(scale(clean_values)),
                huber_loss: round_values(huber_loss(residuals_vec, 1.0)),
                cor: round_scalar(cor(clean_values, basis_values)),
                cov: round_scalar(cov(clean_values, basis_values)),
                pnorm: round_scalar(pnorm(0.25)),
                pt: round_scalar(pt(1.1, 5)),
                pf: round_scalar(pf(1.2, 3, 6)),
                pchisq: round_scalar(pchisq(2.5, 4))
            ]
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^json
    )

    descriptive_r = node(
        stats_data,
        command = <{
            round_scalar <- function(x) round(as.numeric(x), 8)
            round_values <- function(x) unname(round(as.numeric(x), 8))
            skewness_t <- function(x) {
                m <- mean(x)
                m2 <- mean((x - m)^2)
                if (m2 == 0) return(0)
                mean((x - m)^3) / (m2^(1.5))
            }
            kurtosis_t <- function(x) {
                m <- mean(x)
                m2 <- mean((x - m)^2)
                if (m2 == 0) return(-3)
                mean((x - m)^4) / (m2^2) - 3
            }
            winsorize_t <- function(x, limits = c(0.2, 0.2)) {
                qs <- as.numeric(quantile(x, probs = c(limits[1], 1 - limits[2]), names = FALSE, type = 7))
                pmin(pmax(x, qs[1]), qs[2])
            }
            normalize_t <- function(x) {
                rng <- range(x)
                (x - rng[1]) / (rng[2] - rng[1])
            }
            huber_t <- function(x, delta = 1.0) {
                ifelse(abs(x) <= delta, 0.5 * x^2, delta * (abs(x) - 0.5 * delta))
            }

            clean_values <- stats_data$value
            values_with_na <- stats_data$value_with_na
            basis_values <- stats_data$basis_x
            residuals_vec <- stats_data$actual - stats_data$predicted

            list(
                mean = round_scalar(mean(values_with_na, na.rm = TRUE)),
                median = round_scalar(median(values_with_na, na.rm = TRUE)),
                min = round_scalar(min(values_with_na, na.rm = TRUE)),
                max = round_scalar(max(values_with_na, na.rm = TRUE)),
                range = round_values(range(values_with_na, na.rm = TRUE)),
                var = round_scalar(var(values_with_na, na.rm = TRUE)),
                sd = round_scalar(sd(values_with_na, na.rm = TRUE)),
                iqr = round_scalar(IQR(values_with_na, na.rm = TRUE)),
                mad = round_scalar(mad(clean_values, constant = 1.4826)),
                fivenum = round_values(fivenum(clean_values)),
                quantile = round_values(quantile(values_with_na, probs = c(0.25, 0.5, 0.75), na.rm = TRUE, names = FALSE, type = 7)),
                skewness = round_scalar(skewness_t(clean_values)),
                kurtosis = round_scalar(kurtosis_t(clean_values)),
                trimmed_mean = round_scalar(mean(values_with_na, trim = 0.125, na.rm = TRUE)),
                winsorize = round_values(winsorize_t(clean_values)),
                cv = round_scalar(sd(clean_values) / mean(clean_values)),
                normalize = round_values(normalize_t(clean_values)),
                standardize = round_values(as.numeric(scale(clean_values))),
                scale = round_values(as.numeric(scale(clean_values))),
                huber_loss = round_values(huber_t(residuals_vec, 1.0)),
                cor = round_scalar(cor(clean_values, basis_values)),
                cov = round_scalar(cov(clean_values, basis_values)),
                pnorm = round_scalar(pnorm(0.25)),
                pt = round_scalar(pt(1.1, 5)),
                pf = round_scalar(pf(1.2, 3, 6)),
                pchisq = round_scalar(pchisq(2.5, 4))
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^json
    )

    basis_t = node(
        stats_data,
        command = <{
            poly_cols = poly(pull(stats_data, $basis_x), 3, raw = true)
            basis_core = stats_data |> select($id, $basis_x)
            basis_df = eval(to_expr(mutate(basis_core, !!!poly_cols)))
            basis_df = basis_df
                |> mutate(
                    $bucket = to_string(cut($basis_x, [0.0, 3.0, 6.0, 9.0])),
                    $poly1 = round($poly1, digits = 8),
                    $poly2 = round($poly2, digits = 8),
                    $poly3 = round($poly3, digits = 8)
                )
                |> select($id, $bucket, $poly1, $poly2, $poly3)
            basis_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    basis_r = node(
        stats_data,
        command = <{
            p <- poly(stats_data$basis_x, 3, raw = TRUE)
            data.frame(
                id = stats_data$id,
                bucket = as.character(cut(stats_data$basis_x, breaks = c(0, 3, 6, 9))),
                poly1 = round(p[, 1], 8),
                poly2 = round(p[, 2], 8),
                poly3 = round(p[, 3], 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_summary_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            summary(full)._tidy_df
                |> select($term, $estimate, $std_error, $statistic, $p_value)
                |> mutate(
                    $estimate = round_safe($estimate),
                    $std_error = round_safe($std_error),
                    $statistic = round_safe($statistic),
                    $p_value = round_safe($p_value)
                )
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_summary_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            smry <- as.data.frame(summary(full)$coefficients)
            data.frame(
                term = rownames(smry),
                estimate = round(smry[, 1], 8),
                std_error = round(smry[, 2], 8),
                statistic = round(smry[, 3], 8),
                p_value = round(smry[, 4], 8),
                row.names = NULL
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_coef_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            coef_df = coef(full)
                |> mutate($estimate = round_safe($estimate))
            coef_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_coef_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            vals <- coef(full)
            data.frame(term = names(vals), estimate = round(as.numeric(vals), 8), row.names = NULL)
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_conf_int_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            conf_int_df = conf_int(full)
                |> mutate($lower = round_safe($lower), $upper = round_safe($upper))
            conf_int_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_conf_int_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            ci <- confint(full)
            data.frame(
                term = rownames(ci),
                lower = round(ci[, 1], 8),
                upper = round(ci[, 2], 8),
                row.names = NULL
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_predict_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            preds = predict(stats_data, full)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [
                first: round_safe(get(preds, idx_lens(0))),
                last: round_safe(get(preds, idx_lens(length(preds) - 1))),
                total: round_safe(sum(preds))
            ]
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^json
    )

    model_predict_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            preds <- predict(full, newdata = stats_data)
            list(
                first = round(as.numeric(preds[[1]]), 8),
                last = round(as.numeric(preds[[length(preds)]]), 8),
                total = round(sum(preds), 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^json
    )

    model_residuals_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            resid_df = residuals(stats_data, full)
                |> mutate(
                    $actual = round_safe($actual),
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid)
                )
            resid_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_residuals_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            data.frame(
                actual = round(stats_data$response, 8),
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(residuals(full)), 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_augment_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            augment_df = add_diagnostics(stats_data, full)
                |> select($id, $fitted, $resid, $std_resid)
                |> mutate(
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid),
                    $std_resid = round_safe($std_resid)
                )
            augment_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_augment_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            res <- residuals(full)
            data.frame(
                id = stats_data$id,
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(res), 8),
                std_resid = round(as.numeric(res / sigma(full)), 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_diagnostics_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            diag_df = add_diagnostics(stats_data, full)
                |> select($id, $fitted, $resid, $hat, $sigma, $cooksd, $std_resid)
                |> mutate(
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid),
                    $hat = round_safe($hat),
                    $sigma = round_safe($sigma),
                    $cooksd = round_safe($cooksd),
                    $std_resid = round_safe($std_resid)
                )
            diag_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_diagnostics_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            infl <- lm.influence(full)
            data.frame(
                id = stats_data$id,
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(residuals(full)), 8),
                hat = round(as.numeric(hatvalues(full)), 8),
                sigma = round(as.numeric(infl$sigma), 8),
                cooksd = round(as.numeric(cooks.distance(full)), 8),
                std_resid = round(as.numeric(rstandard(full)), 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_fit_stats_t = node(
        stats_data,
        command = <{
            reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            md_full = full._model_data
            md_red = reduced._model_data
            fit_stats_df = to_dataframe([
                [model: "reduced", r_squared: md_red.r_squared, adj_r_squared: md_red.adj_r_squared, sigma: md_red.sigma, AIC: na_float(), BIC: na_float(), df_residual: md_red.df_residual, nobs: md_red.nobs],
                [model: "full",    r_squared: md_full.r_squared, adj_r_squared: md_full.adj_r_squared, sigma: md_full.sigma, AIC: na_float(), BIC: na_float(), df_residual: md_full.df_residual, nobs: md_full.nobs]
            ])
                |> mutate(
                    $r_squared = round_safe($r_squared),
                    $adj_r_squared = round_safe($adj_r_squared),
                    $sigma = round_safe($sigma),
                    $AIC = round_safe($AIC),
                    $BIC = round_safe($BIC),
                    $df_residual = round_safe($df_residual),
                    $nobs = round_safe($nobs)
                )
            fit_stats_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_fit_stats_r = node(
        stats_data,
        command = <{
            reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            make_row <- function(name, fit) {
                smry <- summary(fit)
                data.frame(
                    model = name,
                    r_squared = round(smry$r.squared, 8),
                    adj_r_squared = round(smry$adj.r.squared, 8),
                    sigma = round(smry$sigma, 8),
                    AIC = round(AIC(fit), 8),
                    BIC = round(BIC(fit), 8),
                    df_residual = round(as.numeric(df.residual(fit)), 8),
                    nobs = round(as.numeric(nobs(fit)), 8)
                )
            }
            rbind(make_row("reduced", reduced), make_row("full", full))
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_compare_t = node(
        stats_data,
        command = <{
            reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            compare_df = compare(reduced, full)
                |> select($term, $estimate_1, $estimate_2, $std_error_1, $std_error_2)
                |> mutate(
                    $estimate_1 = round_safe($estimate_1),
                    $estimate_2 = round_safe($estimate_2),
                    $std_error_1 = round_safe($std_error_1),
                    $std_error_2 = round_safe($std_error_2)
                )
            compare_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_compare_r = node(
        stats_data,
        command = <{
            reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            reduced_smry <- as.data.frame(summary(reduced)$coefficients)
            full_smry <- as.data.frame(summary(full)$coefficients)
            reduced_smry$term <- rownames(reduced_smry)
            full_smry$term <- rownames(full_smry)
            terms <- unique(c(reduced_smry$term, full_smry$term))
            out <- data.frame(term = terms, stringsAsFactors = FALSE)
            out$estimate_1 <- round(reduced_smry[match(terms, reduced_smry$term), 1], 8)
            out$estimate_2 <- round(full_smry[match(terms, full_smry$term), 1], 8)
            out$std_error_1 <- round(reduced_smry[match(terms, reduced_smry$term), 2], 8)
            out$std_error_2 <- round(full_smry[match(terms, full_smry$term), 2], 8)
            out
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_score_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            score_df = score(stats_data, full)
                |> mutate($rmse = round($rmse, digits = 8), $mae = round($mae, digits = 8), $r2 = round($r2, digits = 8))
            score_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_score_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            preds <- predict(full, newdata = stats_data)
            resid <- stats_data$response - preds
            rmse <- sqrt(mean(resid^2))
            mae <- mean(abs(resid))
            r2 <- 1 - sum(resid^2) / sum((stats_data$response - mean(stats_data$response))^2)
            data.frame(rmse = round(rmse, 8), mae = round(mae, 8), r2 = round(r2, 8))
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_anova_t = node(
        stats_data,
        command = <{
            reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_with_na = \(x) { if (is_error(x)) { x } else if (is_na(x)) { na_float() } else { round(x, digits = 8) } }
            anova(reduced, full)
            -- Use internal data access to bypass missing standalone deviance/df_residual builtins in Nix env
            dr_red = reduced._model_data.df_residual
            dr_full = full._model_data.df_residual
            dev_red = reduced._model_data.deviance
            dev_full = full._model_data.deviance
            delta_df = dr_red - dr_full
            delta_dev = dev_red - dev_full
            f_stat = (delta_dev / delta_df) / (dev_full / dr_full)
            p_val = 1 - pf(f_stat, delta_df, dr_full)
            [
                [
                    df_residual: round_with_na(dr_red),
                    deviance: round_with_na(dev_red),
                    delta_df: na_float(),
                    delta_deviance: na_float(),
                    statistic: na_float(),
                    p_value: na_float()
                ],
                [
                    df_residual: round_with_na(dr_full),
                    deviance: round_with_na(dev_full),
                    delta_df: round_with_na(delta_df),
                    delta_deviance: round_with_na(delta_dev),
                    statistic: round_with_na(f_stat),
                    p_value: round_with_na(p_val)
                ]
            ]
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^json
    )

    model_anova_r = node(
        stats_data,
        command = <{
            reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            rows <- list(
                list(
                    df_residual = round(as.numeric(df.residual(reduced)), 8),
                    deviance = round(as.numeric(deviance(reduced)), 8),
                    delta_df = NA_real_,
                    delta_deviance = NA_real_,
                    statistic = NA_real_,
                    p_value = NA_real_
                )
            )
            delta_df <- df.residual(reduced) - df.residual(full)
            delta_dev <- deviance(reduced) - deviance(full)
            f_stat <- (delta_dev / delta_df) / (deviance(full) / df.residual(full))
            p_val <- 1 - pf(f_stat, delta_df, df.residual(full))
            rows[[2]] <- list(
                df_residual = round(as.numeric(df.residual(full)), 8),
                deviance = round(as.numeric(deviance(full)), 8),
                delta_df = round(as.numeric(delta_df), 8),
                delta_deviance = round(as.numeric(delta_dev), 8),
                statistic = round(as.numeric(f_stat), 8),
                p_value = round(as.numeric(p_val), 8)
            )
            rows
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^json
    )

    model_wald_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            wald_df = wald_test(full, terms = ["feature_b", "basis_x"])
                |> select($terms, $statistic, $df, $p_value, $test_type)
                |> mutate(
                    $statistic = round($statistic, digits = 8),
                    $df = round($df, digits = 8),
                    $p_value = round($p_value, digits = 8)
                )
            wald_df
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_wald_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            terms <- c("feature_b", "basis_x")
            beta <- coef(full)[terms]
            vc <- vcov(full)[terms, terms, drop = FALSE]
            q <- length(terms)
            w_stat <- as.numeric(t(beta) %*% solve(vc, beta))
            f_stat <- w_stat / q
            p_val <- 1 - pf(f_stat, q, df.residual(full))
            data.frame(
                terms = paste(terms, collapse = ", "),
                statistic = round(f_stat, 8),
                df = round(as.numeric(q), 8),
                p_value = round(p_val, 8),
                test_type = "F"
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_scalars_t = node(
        stats_data,
        command = <{
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            vc = vcov(full)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [
                nobs: full._model_data.nobs,
                df_residual: full._model_data.df_residual,
                sigma: round_safe(full._model_data.sigma)
            ]
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^json
    )

    model_scalars_r = node(
        stats_data,
        command = <{
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            vc <- vcov(full)
            list(
                nobs = as.integer(nobs(full)),
                df_residual = as.integer(df.residual(full)),
                sigma = round(sigma(full), 8)
            )
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^json
    )

    glm_model_r = node(
        stats_data,
        command = <{
            stats_data$success <- to_factor(stats_data$success, levels = c(0, 1), labels = c("No", "Yes"))
            glm(success ~ feature_a + feature_b, data = stats_data, family = binomial(link = "logit"))
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^pmml
    )

    model_dispersion_t = node(
        glm_model_r,
        command = <{
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [dispersion: round_safe(dispersion(glm_model_r))]
        }>,
        runtime = T,
        deserializer = [glm_model_r: ^pmml],
        serializer = ^json
    )

    model_dispersion_r = node(
        stats_data,
        command = <{
            fit <- glm(success ~ feature_a + feature_b, data = stats_data, family = binomial(link = "logit"))
            list(dispersion = round(summary(fit)$dispersion, 8))
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^json
    )

    validation = node(
        command = <{
            assert(identical(counts_t, counts_r), "n()/n_distinct() results should match dplyr")
            assert(identical(descriptive_t, descriptive_r), "Descriptive stats results should match R")
            assert(identical(basis_t, basis_r), "cut()/poly() results should match R")
            assert(identical(model_summary_t, model_summary_r), "summary() results should match R")
            assert(identical(model_coef_t, model_coef_r), "coef() results should match R")
            assert(identical(model_conf_int_t, model_conf_int_r), "conf_int() results should match R")
            assert(identical(model_predict_t, model_predict_r), "predict() results should match R")
            assert(identical(model_residuals_t, model_residuals_r), "residuals() results should match R")
            assert(identical(model_augment_t, model_augment_r), "add_diagnostics() results should match R")
            assert(identical(model_diagnostics_t, model_diagnostics_r), "add_diagnostics() results should match R")
            assert(identical(model_fit_stats_t, model_fit_stats_r), "fit_stats() results should match R")
            assert(identical(model_compare_t, model_compare_r), "compare() results should match R")
            assert(identical(model_score_t, model_score_r), "score() results should match R")
            assert(identical(model_anova_t, model_anova_r), "anova() results should match R")
            assert(identical(model_wald_t, model_wald_r), "wald_test() results should match R")
            assert(identical(model_scalars_t, model_scalars_r), "nobs()/df_residual()/sigma()/vcov() results should match R")
            assert(identical(model_dispersion_t, model_dispersion_r), "dispersion() results should match R")

            [
                status: "ok",
                checked: 17,
                rows: nrow(stats_data)
            ]
        }>,
        runtime = T,
        deserializer = [
            stats_data: ^arrow,
            counts_t: ^arrow,
            counts_r: ^arrow,
            descriptive_t: ^json,
            descriptive_r: ^json,
            basis_t: ^arrow,
            basis_r: ^arrow,
            model_summary_t: ^arrow,
            model_summary_r: ^arrow,
            model_coef_t: ^arrow,
            model_coef_r: ^arrow,
            model_conf_int_t: ^arrow,
            model_conf_int_r: ^arrow,
            model_predict_t: ^json,
            model_predict_r: ^json,
            model_residuals_t: ^arrow,
            model_residuals_r: ^arrow,
            model_augment_t: ^arrow,
            model_augment_r: ^arrow,
            model_diagnostics_t: ^arrow,
            model_diagnostics_r: ^arrow,
            model_fit_stats_t: ^arrow,
            model_fit_stats_r: ^arrow,
            model_compare_t: ^arrow,
            model_compare_r: ^arrow,
            model_score_t: ^arrow,
            model_score_r: ^arrow,
            model_anova_t: ^json,
            model_anova_r: ^json,
            model_wald_t: ^arrow,
            model_wald_r: ^arrow,
            model_scalars_t: ^json,
            model_scalars_r: ^json,
            model_dispersion_t: ^json,
            model_dispersion_r: ^json
        ],
        serializer = ^json
    )
}

print("Running stats_functions_t demo...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print(res)
    exit(1)
}

report = read_node("validation")
print(report)
assert(report.status == "ok", "stats_functions_t validation failed")

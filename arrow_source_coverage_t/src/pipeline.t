import dataframe
import colcraft
import stats
import math

p = pipeline {
    source_csv = node(
        command = <{
            seed = to_dataframe([
                [id: 1, team: "alpha", amount: 10.0, offset: 2.0, bonus: 1.5, flag: true, note: "alpha,beta", stage: "low"],
                [id: 2, team: "alpha", amount: 14.0, offset: 3.5, bonus: 2.0, flag: false, note: "plain text", stage: "medium"],
                [id: 3, team: "beta", amount: 18.0, offset: 4.0, bonus: na_float(), flag: true, note: "beta,gamma", stage: "high"],
                [id: 4, team: "beta", amount: 22.0, offset: 5.0, bonus: 3.5, flag: true, note: "delta,epsilon", stage: "medium"],
                [id: 5, team: "gamma", amount: 26.0, offset: 6.5, bonus: 4.5, flag: false, note: na_string(), stage: "high"],
                [id: 6, team: "gamma", amount: 30.0, offset: 7.0, bonus: 5.0, flag: true, note: "final,row", stage: "low"]
            ])
            print("Seed type:")
            print(type(seed))
            csv_path = "arrow_source_coverage_seed.csv"
            res_w = write_csv(seed, csv_path)
            print("Write result:")
            print(res_w)
            read_csv(csv_path)
        }>,
        runtime = T,
        serializer = ^arrow
    )

    arrow_roundtrip = node(
        command = <{
            arrow_path = "arrow_source_coverage.arrow"
            write_arrow(source_csv, arrow_path)
            read_arrow(arrow_path)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    compute_features = node(
        command = <{
            arrow_roundtrip
                |> mutate(
                    $stage = to_factor($stage, levels = ["low", "medium", "high"], ordered = true),
                    $net = $amount - $offset,
                    $gap = abs($amount - 18.0),
                    $log_amount = log($amount),
                    $sqrt_amount = sqrt($amount),
                    $amount_sq = pow($amount, 2.0),
                    $exp_offset = exp($offset / 10.0),
                    $row_id = row_number($amount),
                    $min_rank = min_rank($amount),
                    $dense = dense_rank($amount),
                    $pct_rank = percent_rank($amount),
                    $cume = cume_dist($amount),
                    $prev_amount = lag($amount),
                    $prev_two = lag($amount, 2),
                    $next_amount = lead($amount),
                    $next_two = lead($amount, 2),
                    $running_amount = cumsum($amount)
                )
                |> relocate($note, .before = $team)
                |> rename(segment = $team)
                |> arrange($amount)
                |> distinct()
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    top_slice = node(
        command = compute_features |> arrange($amount, direction = "desc") |> slice([0, 1, 2]),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    active_projection = node(
        command = compute_features |> filter($flag) |> select($id, $segment, $amount, $net, $stage),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    segment_counts = node(
        command = count(compute_features, $segment),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    grouped_summary = node(
        command = compute_features
            |> mutate(stage_s = to_string($stage))
            |> group_by($segment)
            |> summarize(
                avg_amount = mean($amount),
                min_amount = min($amount),
                max_amount = max($amount),
                unique_stages = n_distinct($stage_s),
                total_bonus = sum($bonus, na_rm = true),
                last_running = max($running_amount)
            )
            |> arrange($segment),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    aggregate_snapshot = node(
        command = compute_features
            |> summarize(
                min_amount = min($amount),
                max_amount = max($amount),
                unique_segments = n_distinct($segment),
                avg_exp_offset = mean($exp_offset)
            ),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    nested_groups = node(
        command = compute_features |> group_by($segment) |> nest(),
        runtime = T,
        deserializer = ^arrow
    )

    roundtrip_nested = node(
        command = nested_groups |> unnest($data) |> arrange($id),
        runtime = T,
        serializer = ^arrow
    )

    model_diagnostics = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(model, data = compute_features)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_predictions = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            predict(compute_features, model)
        }>,
        runtime = T,
        deserializer = ^arrow
    )

    model_augmented = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(compute_features, model)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_residuals = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            residuals(compute_features, model)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_coefficients = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            coef(model)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_confidence = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            conf_int(model)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_fit_stats = node(
        command = <{
            reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            fit_stats([reduced: reduced, full: full])
        }>,
        runtime = T,
        deserializer = ^arrow
    )

    model_anova = node(
        command = <{
            reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            anova(reduced, full)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    model_wald = node(
        command = <{
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            wald_test(model, terms = ["offset"])
        }>,
        runtime = T,
        deserializer = ^arrow
    )

    validation_report = node(
        command = <{
            assert(nrow(source_csv) == 6, "CSV roundtrip should preserve all rows")
            assert(get(pull(arrow_roundtrip, $note), 0) == "alpha,beta", "CSV quoting should roundtrip commas")
            assert(nrow(top_slice) == 3, "slice() should keep the requested number of rows")
            assert(nrow(active_projection) == 4, "filter() should keep the four flagged rows")
            assert(ncol(active_projection) == 5, "select() should project the requested columns")
            assert(sum(pull(segment_counts, $n)) == 6, "count() totals should match the input rows")
            assert(nrow(grouped_summary) == 3, "summarize() should emit one row per segment")
            assert(get(pull(aggregate_snapshot, $unique_segments), 0) == 3, "aggregate snapshot should see three segments")
            assert(nrow(roundtrip_nested) == nrow(compute_features), "nest()/unnest() should preserve row count")
            assert(ncol(model_diagnostics) > ncol(compute_features), "add_diagnostics() should append diagnostic columns")
            assert(nrow(model_predictions) == nrow(compute_features), "predict() should return one row per input row")
            assert(ncol(model_augmented) > ncol(compute_features), "add_diagnostics() should append fitted values")
            assert(nrow(model_residuals) == nrow(compute_features), "residuals() should return one row per input row")
            assert(nrow(model_coefficients) == 4, "coef() should expose all model terms")
            assert(nrow(model_confidence) == 4, "conf_int() should expose all confidence intervals")
            assert(nrow(model_fit_stats) == 2, "fit_stats() should stack the reduced and full models")
            assert(nrow(model_anova) >= 1, "anova() should produce a comparison table")
            assert(nrow(model_wald) == 1, "wald_test() should return a single summary row")

            model = lm(data = compute_features, formula = amount ~ offset + stage)
            model_summary = summary(model)
            corr = cor(pull(compute_features, $amount), pull(compute_features, $net))
            expected_model_terms = 4 -- (Intercept), offset, stage.medium, stage.high

            assert(nrow(model_summary._tidy_df) == expected_model_terms, "lm() summary should expose all model terms")
            assert(!is_na(corr), "cor() should produce a numeric result")

            [
                status: "ok",
                corr: corr,
                rows: nrow(compute_features),
                grouped_rows: nrow(grouped_summary),
                diagnostics_cols: ncol(model_diagnostics)
            ]
        }>,
        runtime = T,
        deserializer = [
            source_csv: ^arrow,
            arrow_roundtrip: ^arrow,
            top_slice: ^arrow,
            active_projection: ^arrow,
            segment_counts: ^arrow,
            grouped_summary: ^arrow,
            aggregate_snapshot: ^arrow,
            roundtrip_nested: ^arrow,
            compute_features: ^arrow,
            model_diagnostics: ^arrow,
            model_augmented: ^arrow,
            model_residuals: ^arrow,
            model_coefficients: ^arrow,
            model_confidence: ^arrow,
            model_anova: ^arrow
        ]
    )
}

print("Running arrow source coverage demo...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print(res)
    exit(1)
}

feature_preview = read_node(p.compute_features)
summary_preview = read_node(p.grouped_summary)
report = read_node(p.validation_report)

print("Feature preview:")
glimpse(feature_preview)
print("Grouped summary:")
print(summary_preview)
print("Validation report:")
print(report)

assert(report.status == "ok", "Arrow source coverage demo failed")

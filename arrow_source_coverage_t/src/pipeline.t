import dataframe
import colcraft
import stats

p = pipeline {
    source_csv = node(
        command = <{
            seed = dataframe([
                [id: 1, team: "alpha", amount: 10.0, offset: 2.0, bonus: 1.5, flag: true, note: "alpha,beta", stage: "low"],
                [id: 2, team: "alpha", amount: 14.0, offset: 3.5, bonus: 2.0, flag: false, note: "plain text", stage: "medium"],
                [id: 3, team: "beta", amount: 18.0, offset: 4.0, bonus: na_float(), flag: true, note: "beta,gamma", stage: "high"],
                [id: 4, team: "beta", amount: 22.0, offset: 5.0, bonus: 3.5, flag: true, note: "delta,epsilon", stage: "medium"],
                [id: 5, team: "gamma", amount: 26.0, offset: 6.5, bonus: 4.5, flag: false, note: na_string(), stage: "high"],
                [id: 6, team: "gamma", amount: 30.0, offset: 7.0, bonus: 5.0, flag: true, note: "final,row", stage: "low"]
            ])

            csv_path = "arrow_source_coverage_seed.csv"
            write_csv(seed, csv_path)
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
                    $stage = factor($stage, levels = ["low", "medium", "high"], ordered = true),
                    $net = $amount - $offset,
                    $gap = abs($amount - 18.0),
                    $log_amount = log($amount),
                    $sqrt_amount = sqrt($amount),
                    $row_id = row_number($amount),
                    $dense = dense_rank($amount),
                    $prev_amount = lag($amount),
                    $next_amount = lead($amount),
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
            |> group_by($segment)
            |> summarize(
                avg_amount = mean($amount),
                total_bonus = sum($bonus, na_rm = true),
                last_running = max($running_amount)
            )
            |> arrange($segment),
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
            model = lm(data = compute_features, formula = amount ~ offset + id)
            add_diagnostics(model, data = compute_features)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
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
            assert(nrow(roundtrip_nested) == nrow(compute_features), "nest()/unnest() should preserve row count")
            assert(ncol(model_diagnostics) > ncol(compute_features), "add_diagnostics() should append diagnostic columns")

            model = lm(data = compute_features, formula = amount ~ offset + id)
            model_summary = summary(model)
            corr = cor(pull(compute_features, $amount), pull(compute_features, $net))
            expected_model_terms = length(["(Intercept)", "offset", "id"])

            assert(nrow(model_summary._tidy_df) == expected_model_terms, "lm() summary should expose intercept plus two predictors")
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
            roundtrip_nested: ^arrow,
            compute_features: ^arrow,
            model_diagnostics: ^arrow
        ]
    )
}

print("Running arrow source coverage demo...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print(res)
    exit(1)
}

feature_preview = read_node("compute_features")
summary_preview = read_node("grouped_summary")
report = read_node("validation_report")

print("Feature preview:")
glimpse(feature_preview)
print("Grouped summary:")
print(summary_preview)
print("Validation report:")
print(report)

assert(report.status == "ok", "Arrow source coverage demo failed")

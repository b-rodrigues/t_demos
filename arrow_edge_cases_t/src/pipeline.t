import chrono
import dataframe

p = pipeline {
    seed_csv_files = node(
        command = <{
            native_csv = str_join(
                "id,quoted,note,all_na,date_str,datetime_str,amount\n",
                "1,\"alpha,beta\",keep,,2024-01-31,2024-01-31 23:59:59,1.5\n",
                "2,\"say \"\"hello\"\"\",,,2024-02-29,2024-02-29 12:30:00,2.5\n",
                "3,plain text,\"final,row\",,2024-03-31,2024-03-31 00:15:45,3.5\n"
            )
            fallback_csv = str_join(
                "id;quoted;all_na;flag;date_str\n",
                "1;\"alpha,beta\";;true;2024-01-31\n",
                "2;\"two words\";;false;2024-02-29\n",
                "3;\"say \"\"hello\"\"\";;true;2024-03-31\n"
            )

            write_text("arrow_edge_native.csv", native_csv)
            write_text("arrow_edge_fallback.csv", fallback_csv)

            [status: "ready"]
        }>,
        runtime = T,
        serializer = ^json
    )

    seed_parquet = node(
        command = <{
import pandas as pd

parquet_df = pd.DataFrame({
    "id": [1, 2, 3],
    "category": pd.Series(["low", "medium", "high"], dtype = "category"),
    "event_date": pd.to_datetime(["2024-01-31", "2024-02-29", "2024-03-31"]),
    "event_ts": pd.to_datetime([
        "2024-01-31T23:59:59Z",
        "2024-02-29T12:30:00Z",
        "2024-03-31T00:15:45Z"
    ], utc = True),
    "amount": [10.0, 12.5, 15.0]
})

parquet_df.to_parquet("arrow_edge.parquet", index = False)
seed_parquet = {"status": "ready"}
        }>,
        runtime = Python,
        serializer = ^json
    )

    native_csv = node(
        command = <{
            seed_csv_files
            read_csv("arrow_edge_native.csv")
        }>,
        runtime = T,
        deserializer = ^json,
        serializer = ^arrow
    )

    fallback_csv = node(
        command = <{
            seed_csv_files
            read_csv("arrow_edge_fallback.csv", separator = ";")
        }>,
        runtime = T,
        deserializer = ^json,
        serializer = ^arrow
    )

    parsed_native = node(
        command = native_csv
            |> mutate(
                parsed_date = as_date($date_str),
                parsed_ts = parse_datetime($datetime_str, "%Y-%m-%d %H:%M:%S"),
                parsed_day = day($parsed_date)
            )
            |> arrange($id),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    parquet_scan = node(
        command = <{
            seed_parquet
            read_parquet("arrow_edge.parquet")
        }>,
        runtime = T,
        deserializer = ^json,
        serializer = ^arrow
    )

    r_temporal = node(
        command = <{
            data.frame(
                id = 1:3,
                category = factor(c("low", "medium", "high"), levels = c("low", "medium", "high"), ordered = TRUE),
                event_date = as.Date(c("2024-01-31", "2024-02-29", "2024-03-31")),
                event_ts = as.POSIXct(c("2024-01-31 23:59:59", "2024-02-29 12:30:00", "2024-03-31 00:15:45"), tz = "UTC"),
                amount = c(10.0, 12.5, 15.0)
            )
        }>,
        runtime = R,
        serializer = ^arrow
    )

    py_temporal = node(
        command = <{
import pandas as pd

df = r_temporal.copy()
df["category"] = df["category"].astype("category")
df["score"] = df["amount"] * 2.0
py_temporal = df
        }>,
        runtime = Python,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    temporal_roundtrip = node(
        command = py_temporal
            |> mutate(
                event_date = as_date($event_date),
                event_ts = as_datetime($event_ts),
                event_day = day($event_date)
            )
            |> arrange($id),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )

    validation_report = node(
        command = <{
            assert(nrow(native_csv) == 3, "native CSV should load all rows")
            assert(get(pull(native_csv, $quoted), 0) == "alpha,beta", "quoted commas should survive native CSV ingestion")
            assert(is_na(get(pull(native_csv, $note), 1)), "blank CSV fields should become NA")
            assert(nrow(fallback_csv) == 3, "fallback CSV should load all rows")
            assert(is_na(get(pull(fallback_csv, $all_na), 0)), "fallback CSV should preserve blank NA values")
            assert(get(pull(parsed_native, $parsed_day), 1) == 29, "date parsing should keep leap-day values")
            assert(nrow(parquet_scan) == 3, "Parquet ingestion should load all rows")
            assert(get(pull(parquet_scan, $category), 2) == "high", "Parquet categorical values should roundtrip")
            assert(nrow(temporal_roundtrip) == 3, "R -> Python -> T Arrow roundtrip should keep all rows")
            assert(get(pull(temporal_roundtrip, $event_day), 1) == 29, "temporal Arrow roundtrip should preserve leap-day dates")

            [
                status: "ok",
                native_rows: nrow(native_csv),
                fallback_rows: nrow(fallback_csv),
                parquet_rows: nrow(parquet_scan),
                temporal_rows: nrow(temporal_roundtrip)
            ]
        }>,
        runtime = T,
        deserializer = [
            native_csv: ^arrow,
            fallback_csv: ^arrow,
            parsed_native: ^arrow,
            parquet_scan: ^arrow,
            temporal_roundtrip: ^arrow
        ]
    )
}

print("Running arrow edge-case demo...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print(res)
    exit(1)
}

parsed_preview = read_node("parsed_native")
temporal_preview = read_node("temporal_roundtrip")
report = read_node("validation_report")

print("Parsed CSV preview:")
glimpse(parsed_preview)
print("Temporal roundtrip preview:")
glimpse(temporal_preview)
print("Validation report:")
print(report)

assert(report.status == "ok", "Arrow edge-case demo failed")

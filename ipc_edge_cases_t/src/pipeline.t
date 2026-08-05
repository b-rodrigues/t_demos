import chrono
import dataframe

p = pipeline {
    seed_native_df = node(
        command = <{
            content = str_join([
                "id,quoted,note,all_na,date_str,datetime_str,amount\n",
                "1,\"alpha,beta\",keep,,2024-01-31,2024-01-31 23:59:59,1.5\n",
                "2,\"say \"\"hello\"\"\",,,2024-02-29,2024-02-29 12:30:00,2.5\n",
                "3,plain text,\"final,row\",,2024-03-31,2024-03-31 00:15:45,3.5\n"
            ])
            write_text("n.csv", content)
            read_csv("n.csv")
        }>,
        runtime = T,
        serializer = ^ipc
    )

    seed_fallback_df = node(
        command = <{
            content = str_join([
                "id;quoted;all_na;flag;date_str\n",
                "1;\"alpha,beta\";;true;2024-01-31\n",
                "2;\"two words\";;false;2024-02-29\n",
                "3;\"say \"\"hello\"\"\";;true;2024-03-31\n"
            ])
            write_text("f.csv", content)
            read_csv("f.csv", separator = ";")
        }>,
        runtime = T,
        serializer = ^ipc
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

import os
out_dir = os.environ.get("out", ".")
parquet_path = os.path.join(out_dir, "ipc_edge.parquet")
parquet_df.to_parquet(parquet_path, index = False)
print(f"Wrote parquet to {parquet_path}")
seed_parquet = {"status": "ready", "path": "ipc_edge.parquet"}
        }>,
        runtime = Python,
        serializer = ^json
    )

    native_csv = node(
        command = seed_native_df,
        runtime = T,
        deserializer = ^ipc,
        serializer = ^ipc
    )

    fallback_csv = node(
        command = seed_fallback_df,
        runtime = T,
        deserializer = ^ipc,
        serializer = ^ipc
    )

    parsed_native = node(
        command = native_csv
            |> mutate(
                parsed_date = to_date($date_str),
                parsed_ts = parse_datetime($datetime_str, "%Y-%m-%d %H:%M:%S"),
                parsed_day = day($parsed_date)
            )
            |> arrange($id),
        runtime = T,
        deserializer = ^ipc,
        serializer = ^ipc
    )

    parquet_scan = node(
        command = <{
            _ = seed_parquet
            root = env("T_NODE_seed_parquet")
            parquet_file = path_join(root, "ipc_edge.parquet")
            read_parquet(parquet_file)
        }>,
        runtime = T,
        deserializer = ^json,
        serializer = ^ipc
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
        serializer = ^ipc
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
        deserializer = ^ipc,
        serializer = ^ipc
    )

    temporal_roundtrip = node(
        command = py_temporal
            |> mutate(
                event_date = to_date($event_date),
                event_ts = to_datetime($event_ts),
                event_day = day($event_date)
            )
            |> arrange($id),
        runtime = T,
        deserializer = ^ipc,
        serializer = ^ipc
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
            native_csv: ^ipc,
            fallback_csv: ^ipc,
            parsed_native: ^ipc,
            parquet_scan: ^ipc,
            temporal_roundtrip: ^ipc
        ]
    )
}

print("Running IPC edge-case demo...")
res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print(res)
    exit(1)
}

parsed_preview = read_node(p.parsed_native)
temporal_preview = read_node(p.temporal_roundtrip)
report = read_node(p.validation_report)

print("Parsed CSV preview:")
glimpse(parsed_preview)
print("Temporal roundtrip preview:")
glimpse(temporal_preview)
print("Validation report:")
print(report)

assert(report.status == "ok", "Arrow edge-case demo failed")

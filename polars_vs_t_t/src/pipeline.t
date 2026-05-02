import colcraft
import dataframe

p = pipeline {
    -- Python node using Polars for high-performance data generation and transformation
    polars_node = node(
        command = <{
            import polars as pl
            # Generate some data in Polars
            df = pl.DataFrame({
                "category": ["A", "A", "B", "B", "C", "C"] * 1000,
                "value1": [1.5, 2.5, 3.5, 4.5, 5.5, 6.5] * 1000,
                "value2": [10, 20, 30, 40, 50, 60] * 1000,
                "status": ["ok", "warn", "ok", "error", "ok", "ok"] * 1000
            })
            
            # Polars-style transformations
            df = df.with_columns([
                (pl.col("value1") * pl.col("value2")).alias("product"),
                pl.col("status").str.to_uppercase().alias("status_upper")
            ]).filter(
                pl.col("status") != "error"
            )
            
            # T-Lang will automatically convert this Polars DataFrame to Arrow 
            # and then to a T DataFrame because we use serializer = ^arrow
            df
        }>,
        runtime = Python,
        serializer = ^arrow
    );

    -- T node consuming Polars output and performing native aggregations
    t_summary = node(
        command = polars_node
              |> group_by($category)
              |> summarize(
                avg_product = mean($product),
                max_v2 = max($value2),
                count = n()
              ),
        runtime = T,
        deserializer = ^arrow
    )
}

print("Running Polars vs T-Lang native pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node("t_summary")
print("Summarized results from T-Lang (post-Polars processing):")
print(res)

import colcraft
import dataframe
import stats
import "src/across.t"

p = pipeline {
    -- R node using advanced dplyr features like across()
    r_across = node(
        command = <{
            library(dplyr)
            set.seed(42)
            df <- data.frame(
                id = 1:10,
                val_a = runif(10, 10, 20),
                val_b = runif(10, 100, 200),
                val_c = runif(10, 1, 2),
                tag = sample(c("X", "Y"), 10, replace = TRUE),
                stringsAsFactors = FALSE
            )
            
            # Use across() to rescale all numeric columns starting with 'val'
            df <- df %>%
                mutate(across(starts_with("val"), ~ .x / 10)) %>%
                relocate(tag, .before = id)
            
            df
        }>,
        runtime = R,
        serializer = ^arrow
    );

    t_native = node(
        command = r_across
              |> mutate(
                val_a_log = log($val_a),
                status = if ($val_c > 0.15) { "High" } else { "Low" }
              )
              |> relocate($status, .before = $tag),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- T node using the across() implementation
    t_across = node(
        command = r_across
              |> mutate_across(["val_a", "val_b", "val_c"], \(x) x * 2),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- T node using summarize_across
    t_summary = node(
        command = r_across
              |> summarize_across(["val_a", "val_b", "val_c"], mean),
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )
}

print("Running Advanced Dplyr (across, relocate) vs T-Lang pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node("t_across")
print("T-Lang across() result preview:")
glimpse(res)

print("T-Lang summarize_across() result:")
res_sum = read_node("t_summary")
print(res_sum)

print("Columns relocated by T-Lang:")
print(colnames(res))

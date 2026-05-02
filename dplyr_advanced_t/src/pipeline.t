import colcraft
import dataframe
import stats

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

    -- T node showing native equivalents and additional transformations
    t_native = node(
        command = r_across
              |> mutate(
                -- T performs per-row or vectorized mutation
                val_a_log = log($val_a),
                -- Complex conditional logic in T
                status = if ($val_c > 0.15) { "High" } else { "Low" }
              )
              -- T-Lang relocate supports symbol references
              |> relocate($status, .before = $tag),
        runtime = T,
        deserializer = ^arrow
    )
}

print("Running Advanced Dplyr (across, relocate) vs T-Lang pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node("t_native")
print("Transformed result preview:")
glimpse(res)

print("Columns relocated by T-Lang:")
print(colnames(res))

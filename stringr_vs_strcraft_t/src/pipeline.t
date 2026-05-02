import strcraft
import colcraft
import dataframe

p = pipeline {
    -- R node using stringr
    r_strings = node(
        command = <{
            library(stringr)
            df <- data.frame(
                raw = c("  Hello World  ", "t-lang is cool", "regex 123 test"),
                stringsAsFactors = FALSE
            )
            df$r_trimmed <- str_trim(df$raw)
            df$r_upper <- str_to_upper(df$raw)
            df$r_has_digit <- str_detect(df$raw, "\\d")
            df$r_replaced <- str_replace(df$raw, "cool", "awesome")
            df
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- T node using strcraft
    comparison = node(
        command = r_strings
              |> mutate(
                t_trimmed = str_trim($raw),
                t_upper = to_upper($raw),
                t_has_digit = str_detect($raw, "\\d"),
                t_replaced = str_replace($raw, "cool", "awesome")
              ),
        runtime = T,
        deserializer = ^arrow
    )
}

print("Running stringr vs strcraft comparison pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node("comparison")

print("Comparison Results:")
glimpse(res)

print("Checking detection parity:")
res 
  |> select($raw, $r_has_digit, $t_has_digit)
  |> print()

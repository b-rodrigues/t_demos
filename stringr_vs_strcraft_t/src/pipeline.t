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

res = read_node(p.comparison)

print("Comparison Results:")
glimpse(res)

print("Checking detection parity:")
res 
  |> select($raw, $r_has_digit, $t_has_digit)
  |> print()

-- Node correctness assertions
r_res = read_node(p.r_strings)
assert(type(r_res.error) == "NA", "r_strings node should succeed")
assert(type(res.error) == "NA", "comparison node should succeed")

-- Verify string operation parity between R stringr and T strcraft
all_match = all(res.r_has_digit == res.t_has_digit)
assert(all_match, "all digit detection results should match between R and T")

r_trimmed = res.r_trimmed
t_trimmed = res.t_trimmed
all_trim_match = all(r_trimmed == t_trimmed)
assert(all_trim_match, "all trim results should match")

r_upper = res.r_upper
t_upper = res.t_upper
all_upper_match = all(r_upper == t_upper)
assert(all_upper_match, "all upper results should match")

print("✓ stringr_vs_strcraft_t: all assertions passed")

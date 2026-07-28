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
res = res |> mutate(.digit_match = $r_has_digit .== $t_has_digit)
digit_fails = filter(res, \(r) !r.digit_match)
assert(nrow(digit_fails) == 0, "all digit detection results should match between R and T")

res = res |> mutate(.trim_match = $r_trimmed .== $t_trimmed)
trim_fails = filter(res, \(r) !r.trim_match)
assert(nrow(trim_fails) == 0, "all trim results should match")

res = res |> mutate(.upper_match = $r_upper .== $t_upper)
upper_fails = filter(res, \(r) !r.upper_match)
assert(nrow(upper_fails) == 0, "all upper results should match")

print("✓ stringr_vs_strcraft_t: all assertions passed")

import chrono

csv_text = str_join(
    "id;quoted;all_na;date_str\n",
    "1;\"alpha,beta\";;2024-01-31\n",
    "2;\"two words\";;2024-02-29\n",
    "3;\"say \"\"hello\"\"\";;2024-03-31\n"
)

write_text("arrow_disable_arrow.csv", csv_text)

df = read_csv("arrow_disable_arrow.csv", separator = ";")
parsed = df
    |> mutate(
        parsed_date = as_date($date_str),
        parsed_day = day($parsed_date)
    )
    |> arrange($id)

print("Fallback CSV preview:")
glimpse(parsed)

assert(nrow(parsed) == 3, "fallback script should load all rows")
assert(get(pull(parsed, $quoted), 0) == "alpha,beta", "fallback parser should preserve quoted commas")
assert(is_na(get(pull(parsed, $all_na), 1)), "fallback parser should preserve blank NA values")
assert(get(pull(parsed, $parsed_day), 1) == 29, "fallback parser should preserve leap-day parsing")

print("Fallback Arrow-disabled validation passed")

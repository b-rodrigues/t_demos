import chrono
import colcraft
import dataframe

p = pipeline {
    -- R node using lubridate
    r_dates = node(
        command = <{
            library(lubridate)
            df <- data.frame(
                date_str = c("2023-01-01", "2023-05-15", "2023-12-31"),
                stringsAsFactors = FALSE
            )
            df$parsed <- ymd(df$date_str)
            df$r_year <- year(df$parsed)
            df$r_month <- month(df$parsed)
            df$r_day <- day(df$parsed)
            # Note: adding months in R might behave differently for end of month, 
            # but for these dates it's fine.
            df$r_plus_one_month = df$parsed + months(1)
            df
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- T node using chrono
    -- We take r_dates as input just to demonstrate dependency, 
    -- but we could also just run it independently.
    comparison = node(
        command = r_dates
              |> mutate(
                t_parsed = ymd($date_str),
                t_year = year($t_parsed),
                t_month = month($t_parsed),
                t_day = day($t_parsed),
                t_plus_one_month = $t_parsed + months(1)
              ),
        runtime = T,
        deserializer = ^arrow
    )
}

print("Running chrono vs lubridate comparison pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node(p.comparison)

print("Comparison Results:")
glimpse(res)

-- Simple check
print("Checking year parity:")
res 
  |> mutate(year_match = $r_year == $t_year)
  |> select($date_str, $r_year, $t_year, $year_match)
  |> print()

-- Node correctness assertions
r_d = read_node(p.r_dates)
assert(type(r_d.error) == "NA", "r_dates node should succeed")
assert(type(read_node(p.comparison).error) == "NA", "comparison node should succeed")

-- Verify lubridate/chrono parity
all_match = all(res.r_year == res.t_year)
assert(all_match, "year parity: all r_year should match t_year")
all_month = all(res.r_month == res.t_month)
assert(all_month, "month parity: all r_month should match t_month")
all_day = all(res.r_day == res.t_day)
assert(all_day, "day parity: all r_day should match t_day")

print("✓ chrono_vs_lubridate_t: all assertions passed")

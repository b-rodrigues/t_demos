t_make()
df = read_node(p.py_temporal)
print("Input df:")
glimpse(df)

print("Testing to_date:")
res1 = to_date(df.event_date)
print(res1)

print("Testing to_datetime:")
res2 = to_datetime(df.event_ts)
print(res2)

print("Testing day:")
res3 = day(res1)
print(res3)

print("Testing mutate:")
df2 = df |> mutate(
    event_date = to_date($event_date),
    event_ts = to_datetime($event_ts),
    event_day = day($event_date)
)
print(df2)

t_make()
py_temporal = read_node(p.py_temporal)
res = py_temporal
    |> mutate(
        event_date = to_date($event_date),
        event_ts = to_datetime($event_ts),
        event_day = day($event_date)
    )
    |> arrange($id)
print(res)

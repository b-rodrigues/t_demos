-- Spirograph math functions
-- Inspired by https://github.com/wjschne/spiro

pi = 3.141592653589793

spirograph_points = \(fixed_radius, cycling_radius) {
  num_points = 10000
  max_t = 30 * pi
  t_values = float_seq(0, max_t, num_points)
  diff = fixed_radius - cycling_radius
  ratio = diff / cycling_radius
  xs = t_values |> map(\(t) diff * cos(t) + cos(t * ratio))
  ys = t_values |> map(\(t) diff * sin(t) - sin(t * ratio))
  to_dataframe([x: xs, y: ys, fixed_radius: fixed_radius, cycling_radius: cycling_radius])
}

import colcraft
import dataframe
import lens

-- Generic fold for recursion
fold = \(xs, init, f, self) {
  match (xs) {
    [] => init,
    [h, ..t] => self(t, f(init, h), f, self)
  }
}

-- Implementation of mutate_across
mutate_across = \(df: DataFrame, cols: List[String], fn: Any) {
  fold(cols, df, \(acc: DataFrame, col: String) {
     over(acc, col_lens(col), \(v: Any) { map(v, fn) })
  }, fold)
}

-- Implementation of summarize_across
summarize_across = \(df: DataFrame, cols: List[String], fn: Any) {
  results = map(cols, \(c: String) {
     col_data = get(df, col_lens(c))
     res = fn(col_data)
     (c, [res])
  })
  dataframe(results)
}

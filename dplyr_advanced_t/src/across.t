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
  muts = fold(cols, [], \(acc, c) {
     col_sym = to_symbol("$" + c)
     e = expr(!!fn(!!col_sym))
     [!!c := !!e, !!!acc]
  }, fold)
  eval(expr(!!df |> summarize(!!!muts)))
}

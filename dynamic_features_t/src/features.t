import colcraft
import dataframe
import math
import stats

-- Helper for recursion
fold = \(xs, init, f, self) {
  match (xs) {
    [] => init,
    [h, ..t] => self(t, f(init, h), f, self)
  }
}

-- Apply a single transformation dynamically
apply_transform = \(df, spec) {
  col = spec.col
  t_type = spec.type
  suffix = if (is_na(spec.suffix)) { str_join(["_", t_type]) } else { spec.suffix }
  new_name = str_join([col, suffix])
  
  if (t_type == "log") {
     e = expr(\(d) log(get(d, !!col)))
     m = [!!new_name := !!e]
     eval(expr(!!df |> mutate(!!!m)))
  } else if (t_type == "sqrt") {
     e = expr(\(d) sqrt(get(d, !!col)))
     m = [!!new_name := !!e]
     eval(expr(!!df |> mutate(!!!m)))
  } else if (t_type == "scale") {
     v = get(df, col)
     m_val = mean(v)
     s_val = sd(v)
     e = expr(\(d) (get(d, !!col) - !!m_val) / !!s_val)
     mut = [!!new_name := !!e]
     eval(expr(!!df |> mutate(!!!mut)))
  } else {
     df
  }
}

-- Entry point for dynamic engineering
engineer_features = \(df, specs) {
  fold(specs, df, apply_transform, fold)
}

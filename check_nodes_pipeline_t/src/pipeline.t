-- check_nodes_pipeline_t
-- A comprehensive demo for checking nodes in multi-language pipelines
-- working together with various object types and serializers.

p = pipeline {
  -- 1. T node: A simple list of values
  -- This will be serialized using T's default serializer (Tobj/JSON-like)
  data_t = [1, 2, 3, 4, 5, "hello", [key: "value"]]

  -- 2. R node: Create a DataFrame and serialize as Arrow
  -- Depends on nothing
  df_r = rn(
    command = <{
      library(dplyr)
      df_r <- data.frame(
        id = 1:10,
        val = rnorm(10),
        group = rep(c("A", "B"), each = 5)
      )
    }>,
    serializer = "arrow"
  )

  -- 3. Python node: Consume Arrow DF from R, add a column, and output as Arrow
  -- Depends on df_r
  df_py = pyn(
    command = <{
import pandas as pd
# df_r is automatically deserialized from arrow because we specified it
df_py = df_r.copy()
df_py['val_py'] = df_py['val'] * 2
df_py['is_high'] = (df_py['val_py'] > 0).astype(int)
df_py['lang'] = 'python'
    }>,
    deserializer = "arrow",
    serializer = "arrow"
  )

  -- 4. R node: Create a ggplot graph
  -- Depends on df_r
  plot_r = rn(
    command = <{
      library(ggplot2)
      plot_r <- ggplot(df_r, aes(x = group, y = val)) +
        geom_boxplot() +
        theme_minimal()
    }>,
    deserializer = "arrow"
  )

  -- 5. R node: Linear model (lm)
  -- Produces a complex R object (RDS serialized)
  lm_r = rn(
    command = <{
      lm(val_py ~ val + group, data = df_py)
    }>,
    deserializer = "arrow"
  )

  -- 6. R node: Generalized Linear Model (glm)
  -- Produces a complex R object (RDS serialized)
  glm_r = rn(
    command = <{
      glm(is_high ~ val, data = df_py, family = binomial)
    }>,
    deserializer = "arrow"
  )

  -- 7. Python node: Linear Regression (scikit-learn)
  -- Produces a scikit-learn model object (pickle serialized)
  lm_py = pyn(
    command = <{
  from sklearn.linear_model import LinearRegression
  X = df_py[['val']]
  y = df_py['val_py']
  lm_py = LinearRegression().fit(X, y)
    }>,
    deserializer = "arrow"
  )

  -- 8. Python node: Logit model (statsmodels)
  -- Produces a statsmodels model object (pickle serialized)
  logit_py = pyn(
    command = <{
  import statsmodels.api as sm
  X = sm.add_constant(df_py[['val']])
  y = df_py['is_high']
  logit_py = sm.Logit(y, X).fit()
    }>,
    deserializer = "arrow"
  )

  -- 9. R node: Hand-written summary (JSON)
  -- Uses JSON for easy cross-language inspection
  model_r_json = rn(
    command = <{
      library(dplyr)
      # df_py is deserialized from arrow
      model <- lm(val_py ~ val, data = df_py)
      model_r_json <- list(
        coefficients = coef(model),
        r_squared = summary(model)$r.squared
      )
    }>,
    deserializer = "arrow",
    serializer = "json"
  )

  -- 10. Python node: A vector (numpy array)
  -- Serialized as JSON
  vector_py = pyn(
    command = <{
  import numpy as np
  vector_py = np.linspace(0, 1, 10).tolist()
    }>,
    serializer = "json"
  )

  -- 11. Bash node: Glue it all together
  -- Bash nodes use 'text' serializer by default.
  -- They receive paths to artifacts in environment variables.
  -- We can also use read_node results if we were in a T script, 
  -- but here it's a pipeline node.
  res_bash = shn(
    command = <{
      echo "Processing summary from Bash"
      echo "T Data: $T_NODE_data_t"
      echo "R Model JSON Summary: $(cat $T_NODE_model_r_json/artifact)"
      echo "R LM Model (RDS path): $T_NODE_lm_r/artifact"
      echo "R GLM Model (RDS path): $T_NODE_glm_r/artifact"
      echo "Python LM Model (Pickle path): $T_NODE_lm_py/artifact"
      echo "Python Logit Model (Pickle path): $T_NODE_logit_py/artifact"
      echo "Python Vector (JSON): $(cat $T_NODE_vector_py/artifact)"
      echo "Python DF (Arrow path): $T_NODE_df_py/artifact"
      
      # Just output some text
      echo "All nodes executed successfully" > summary.txt
    }>,
    serializer = "text"
  )

  -- 8. Quarto Report
  -- 12. Quarto Report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize the pipeline
-- This generates the Nix infrastructure and runs the build.
build_pipeline(p)

-- Copy artifacts to local _pipeline/ directory for inspection
pipeline_copy()

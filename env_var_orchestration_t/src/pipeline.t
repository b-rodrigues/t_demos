-- Demo: Environment variable injection and dynamic pipeline lifecycle.

-- Define global configuration
config = [
  db_user: "t_orchestrator",
  timeout: 30
]

p = pipeline {
  -- 1. Pass T-native values into an R runtime as environment variables
  r_node = rn(
    command = <{ 
      user <- Sys.getenv("DB_USER")
      tout <- Sys.getenv("TIMEOUT")
      msg <- paste("User:", user, "with timeout:", tout)
    }>,
    env_vars: [
      DB_USER: config.db_user,
      TIMEOUT: config.timeout
    ]
  )

  -- 2. Pass into a Python runtime
  py_node = pyn(
    command = <{ 
      import os
      u = os.environ.get("DB_USER")
      t = os.environ.get("TIMEOUT")
      res = f"Python saw {u} and {t}"
    }>,
    env_vars: [
      DB_USER: config.db_user,
      TIMEOUT: config.timeout
    ]
  )
}

build_pipeline(p, verbose=1)

-- Node correctness assertions (env vars should pass through)
r_rnode = read_node(p.r_node)
check(is_error(r_rnode) == false)

r_pynode = read_node(p.py_node)
check(is_error(r_pynode) == false)

print("✓ env_var_orchestration_t: all assertions passed")

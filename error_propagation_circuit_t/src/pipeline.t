-- Demo: First-class error values, pipe short-circuiting, and in-node recovery.
--
-- Important: errors propagate across pipeline nodes and cannot be recovered
-- across node boundaries. All recovery patterns (match, ?|>) must happen
-- *within* a single node's command expression.

p = pipeline {
  -- 1. A node that computes something safely
  good_val = node(command = 100 / 5)

  -- 2. A node that intentionally triggers an error (division by zero)
  --    The error is a first-class value: it doesn't crash T.
  error_val = node(command = 10 / 0)

  -- 3. Within a single node, recover from a potential error using 'match'.
  --    We deliberately try a risky operation and handle the Error case.
  recovered_div = node(command = {
    risky = 42 / 0
    match(risky) {
      Error { msg } => 0,
      default => risky
    }
  })

  -- 4. Using the Maybe-Pipe (?|>) for inline error bypass.
  --    Unlike |>, ?|> always passes the value (even an Error) to the next function.
  maybe_recovery = node(command = {
    risky = 99 / 0
    risky ?|> \(x) if (is_error(x)) { -1 } else { x }
  })

  -- 5. Standard pipe (|>) short-circuits on error automatically.
  --    This node shows that |> propagates a local error without crashing.
  short_circuit = node(command = {
    risky = 1 / 0
    risky |> \(x) x + 100
  })
}

build_pipeline(p)

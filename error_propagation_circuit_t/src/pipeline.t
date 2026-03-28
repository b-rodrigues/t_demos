-- Demo: First-class error values, pipe short-circuiting, and in-node recovery.
--
-- Key rule: every pipeline node's command must evaluate to a non-error value,
-- otherwise build_pipeline treats it as a build failure.
-- Recovery patterns (match, ?|>) must fully resolve errors within the same node.

p = pipeline {
  -- 1. A node that computes something safely — no error
  good_val = node(command = 100 / 5)

  -- 2. Recover from a risky division using 'match':
  --    The Error value is caught and replaced with a default of 0.
  recovered_with_match = node(command = {
    risky = 42 / 0
    match(risky) {
      Error { msg } => 0,
      default => risky
    }
  })

  -- 3. Recover using the Maybe-Pipe (?|>):
  --    Unlike |>, ?|> passes Error values through to the handler function,
  --    allowing inline recovery without a match expression.
  recovered_with_maybe_pipe = node(command = {
    risky = 99 / 0
    risky ?|> \(x) if (is_error(x)) { -1 } else { x }
  })

  -- 4. Show how |> short-circuits and how to recover after:
  --    The short-circuited error is caught with a subsequent ?|> recovery.
  short_circuit_then_recover = node(command = {
    risky = 1 / 0
    piped = risky |> \(x) x + 100      -- short-circuits, piped = Error
    piped ?|> \(x) if (is_error(x)) { 0 } else { x }  -- recover
  })
}

build_pipeline(p)

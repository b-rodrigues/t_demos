-- Demo: Resiliency patterns using Errors as data and the 'match' operator.

p = pipeline {
  -- 1. A node that returns a regular value
  input_data = node(command = [ status: "ok", val: 42 ])

  -- 2. A node that intentionally returns an error value (e.g. division by zero)
  errored_node = node(command = 10 / 0)

  -- 3. Standard pipe (|>) short-circuits on Error
  -- This node will receive the error from node2 and propagate it immediately.
  propagated_error = node(command = errored_node |> mutate(foo: "bar"))

  -- 4. Recovery using 'match'
  -- We can pattern match on errors to provide default values or alternatives.
  recovered_val = node(command = match(errored_node) {
    Error { msg } => { 
      print(str_join(["Warning: errored_node failed with msg: ", msg], sep = ""))
      0 
    },
    default => errored_node
  })

  -- 5. Using the Maybe-Pipe (?|>) for bypass
  -- Unlike |>, ?|> forwards the error to the function, enabling recovery inside the lambda.
  maybe_recovery = node(command = errored_node ?|> \(x) {
    if (is_error(x)) { 999 } else { x }
  })
}

build_pipeline(p)

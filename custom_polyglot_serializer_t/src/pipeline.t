-- Demo: Defining a custom YAML serializer as a first-class T object.
--
-- The serializer is fully self-contained in src/yaml_serializer.t —
-- no external .py or .R helper files are needed.
-- Helper function bodies are embedded via py_functions / r_functions blocks.

import "src/yaml_serializer.t" [yaml_ser]

p = pipeline {
  -- Producer: Python node exported as YAML using the imported serializer
  config_py = pyn(
    command = <{
      config = dict(api="https://api.tlang.org", v="0.51.2")
    }>,
    serializer: yaml_ser
  )

  -- Consumer: R node that reads the YAML artifact via the imported serializer
  config_r = rn(
    command = <{
      print(config_py$api)
      res <- paste("URL:", config_py$api)
    }>,
    deserializer: [ config_py: yaml_ser ]
  )
}

build_pipeline(p, verbose=1)

-- Node correctness assertions
assert(type(read_node(p.config_py).error) == "NA", "config_py (Python YAML serializer) should succeed")
assert(type(read_node(p.config_r).error) == "NA", "config_r (R YAML deserializer) should succeed")

print("✓ custom_polyglot_serializer_t: all assertions passed")

-- Demo: Defining a custom YAML serializer using helper files.
--
-- The py_writer/py_reader/r_writer/r_reader snippets in a custom serializer
-- dict must be FUNCTION NAMES (not inline code). The actual function
-- definitions live in helper files, included via functions = [...].

p = pipeline {
  -- Producer: Python node exported as YAML
  -- py_write_yaml is defined in src/yaml_helpers.py
  config_py = pyn(
    command = <{
      config = dict(api="https://api.tlang.org", v="0.51.2")
    }>,
    functions = ["src/yaml_helpers.py"],
    serializer: [
      format: "yaml",
      py_writer: <{ py_write_yaml }>,
      py_reader: <{ py_read_yaml }>
    ]
  )

  -- Consumer: R node reading the YAML artifact
  -- r_read_yaml is defined in src/yaml_helpers.R
  config_r = rn(
    command = <{
      print(config_py$api)
      res <- paste("URL:", config_py$api)
    }>,
    functions = ["src/yaml_helpers.R"],
    deserializer: [
      config_py: [
        format: "yaml",
        r_reader: <{ r_read_yaml }>,
        r_writer: <{ r_write_yaml }>
      ]
    ]
  )
}

build_pipeline(p)

-- Demo: Defining a custom YAML serializer using foreign code snippets.

-- 1. Define the custom serializer
-- Snippets must be provided as foreign code blocks <{ ... }>
yaml_ser = {
  format: "yaml",
  r_writer: <{ yaml::write_yaml(object, path) }>,
  r_reader: <{ yaml::read_yaml(path) }>,
  py_writer: <{ 
    import yaml
    with open(path, "w") as f:
        yaml.dump(obj, f)
  }>,
  py_reader: <{
    import yaml
    with open(path) as f:
        yaml.safe_load(f)
  }>
}

p = pipeline {
  -- 2. Producer: Python dictionary exported as YAML
  config_py = pyn(
    command = <{ 
      config = {
          "api": "https://api.tlang.org",
          "v": "0.51.2"
      }
    }>,
    serializer: yaml_ser
  )

  -- 3. Consumer: R script reading the YAML config
  config_r = rn(
    command = <{ 
      # Accessing as a list in R directly from the YAML artifact
      print(config_py$api)
      res = paste("URL:", config_py$api)
    }>,
    deserializer: { "config_py": yaml_ser }
  )
}

build_pipeline(p)

-- yaml_serializer.t
-- A first-class, self-contained custom YAML serializer.
-- Import in your pipeline with: import "src/yaml_serializer.t" [yaml_ser]
--
-- The r_writer / r_reader / py_writer / py_reader snippets are inline
-- function expressions. T generates a call: <snippet>(result, artifact_path)

yaml_ser = [
  format: "yaml",

  -- R: inline function expressions (no external helper file needed)
  r_writer: <{ function(obj, path) yaml::write_yaml(obj, path) }>,
  r_reader: <{ function(path) yaml::read_yaml(path) }>,

  -- Python: inline lambda expressions
  py_writer: <{ lambda obj, path: __import__('yaml').dump(obj, open(path, 'w'), default_flow_style=False) }>,
  py_reader: <{ lambda path: __import__('yaml').safe_load(open(path)) }>
]

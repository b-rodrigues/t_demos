import yaml

def py_write_yaml(obj, path):
    with open(path, "w") as f:
        yaml.dump(obj, f, default_flow_style=False)

def py_read_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)

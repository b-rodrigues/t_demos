# Shared Python helpers merged into Python nodes via set_pipeline_global_options.
# Intentionally minimal: the file's presence in the node sandbox is what matters.

def describe(df):
    return {"rows": len(df), "cols": len(df.columns)}

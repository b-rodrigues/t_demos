p = pipeline {
    data_node = node(
        command = <{ 
            data = [
                [x: 1.0, y: 0.0],
                [x: 2.0, y: 0.0],
                [x: 3.0, y: 1.0],
                [x: 4.0, y: 1.0],
                [x: 5.0, y: 1.0]
            ]
            to_dataframe(data)
        }>,
        runtime = T,
        serializer = ^ipc
    );
    
    model_node = node(
        command = <{
            import statsmodels.api as sm
            import pandas as pd
            # data_node is a pandas DataFrame
            y = data_node['y']
            X = sm.add_constant(data_node['x'])
            sm.GLM(y, X, family=sm.families.Binomial()).fit()
            # t_write_pmml uses the JPMML-StatsModels bridge for this
        }>,
        runtime = Python,
        serializer = ^pmml,
        deserializer = ^ipc
    )
}

print("Building GLM (Python) pipeline...")
res = build_pipeline(p, verbose=1)
print("Pipeline build successful.")

model = read_node(p.model_node)

print("Model Class:")
print(model.class)

print("Model Family:")
print(model.family)

print("Model Link:")
print(model.link)

print("Coefficients:")
print(model.coefficients)

df_test = read_node(p.data_node)
preds = predict(df_test, model)
print("Predictions type:")
print(type(preds))
print("Predictions:")
print(preds)

-- Node correctness assertions
r_data = read_node(p.data_node)
assert(type(r_data.error) == "NA", "data_node should succeed")
r_model = read_node(p.model_node)
assert(type(r_model.error) == "NA", "model_node (Python GLM) should succeed")
assert(type(preds) != "Error", "predictions should not be an error")

print("✓ glm_basic_py_t: all assertions passed")

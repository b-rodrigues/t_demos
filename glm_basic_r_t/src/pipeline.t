import stats
import dataframe

p = pipeline {
    data_node = node(
        command = <{
            data.frame(
                x = c(1.0, 2.0, 3.0, 4.0, 5.0),
                y = c(0.0, 0.0, 1.0, 1.0, 1.0)
            )
        }>,
        runtime = R,
        serializer = ^arrow
    );
    
    model_node = node(
        command = <{
            data_node$y <- as.factor(data_node$y)
            glm(y ~ x, data = data_node, family = binomial(link = "logit"))
        }>,
        runtime = R,
        serializer = ^pmml,
        deserializer = ^arrow
    )
}

print("Building GLM (R) pipeline...")
res = build_pipeline(p, verbose=1)
print("Build Result:")
print(res)
print("----------------")

model = read_node(p.model_node)

print("Model Summary:")
print(summary(model))

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
assert(type(r_model.error) == "NA", "model_node (R GLM) should succeed")
assert(type(preds) != "Error", "predictions should not be an error")

print("✓ glm_basic_r_t: all assertions passed")

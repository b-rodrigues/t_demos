-- r_py_xgboost_t pipeline mimicking rixpress_demos/r_py_xgboost

p = pipeline {
  -- Load data
  dataset_np = pyn(
    command = <{
from numpy import loadtxt
dataset_np = loadtxt("data/pima-indians-diabetes.csv", delimiter=",")
    }>,
    include = ["data/pima-indians-diabetes.csv"]
  )

  -- Extract features and target
  X = pyn(command = <{ X = dataset_np[:,0:8] }>)
  Y = pyn(command = <{ Y = dataset_np[:,8] }>)

  -- Split data
  splits = pyn(
    command = <{
from sklearn.model_selection import train_test_split
splits = train_test_split(X, Y, test_size=0.33, random_state=7)
    }>
  )

  -- Extract splits
  X_train = pyn(command = <{ X_train = splits[0] }>)
  X_test  = pyn(command = <{ X_test = splits[1] }>)
  y_train = pyn(command = <{ y_train = splits[2] }>)
  y_test  = pyn(command = <{ y_test = splits[3] }>)

  -- Train model
  trained_model = pyn(
    command = <{
from xgboost import XGBClassifier
trained_model = XGBClassifier(use_label_encoder=False, eval_metric="logloss").fit(X_train, y_train)
    }>
  )

  -- Make class predictions
  y_pred = pyn(command = <{ y_pred = trained_model.predict(X_test) }>)

  -- Predict probabilities for ROC curve
  y_proba = pyn(command = <{ y_proba = trained_model.predict_proba(X_test)[:, 1] }>)

  -- Combine test target + probabilities for ROC
  roc_df = pyn(
    command = <{
from pandas import DataFrame
roc_df = DataFrame({"target": y_test, "proba": y_proba})
    }>,
    serializer = ^ipc
  )

  -- Combine into DataFrame
  combined_df = pyn(
    command = <{
from pandas import DataFrame
combined_df = DataFrame({"target": y_test, "prediction": y_pred})
    }>,
    serializer = ^ipc
  )

  -- Confusion matrix in R
  confusion_matrix = rn(
    command = <{ 
library(yardstick)
library(dplyr)
cm_obj = combined_df %>%
  mutate(target = as.factor(target), prediction = as.factor(prediction)) %>%
  conf_mat(truth = target, estimate = prediction)
confusion_matrix = as.data.frame(cm_obj$table)
    }>,
    serializer = ^json,
    deserializer = ^ipc
  )

  -- Accuracy score in Python
  accuracy = pyn(
    command = <{
from sklearn.metrics import accuracy_score
accuracy = accuracy_score(y_test, y_pred)
    }>,
    serializer = ^json,
  )

  -- ROC curve data (FPR, TPR, thresholds) via yardstick
  roc_data = rn(
    command = <{
library(yardstick)
library(dplyr)
roc_data = roc_df %>%
  mutate(target = as.factor(target)) %>%
  roc_curve(truth = target, proba)
    }>,
    serializer = ^ipc,
    deserializer = ^ipc
  )

  -- ROC AUC value via yardstick
  roc_auc = rn(
    command = <{
library(yardstick)
library(dplyr)
roc_auc = roc_df %>%
  mutate(target = as.factor(target)) %>%
  roc_auc(truth = target, proba)
    }>,
    serializer = ^json,
    deserializer = ^ipc
  )

  -- ROC curve plot (manual ggplot, no autoplot)
  roc_plot = rn(
    command = <{
library(yardstick)
library(dplyr)
library(ggplot2)
roc_curve_obj = roc_df %>%
  mutate(target = as.factor(target)) %>%
  roc_curve(truth = target, proba)
roc_plot = ggplot(roc_curve_obj, aes(x = 1 - specificity, y = sensitivity)) +
  geom_path() +
  geom_abline(lty = "dashed") +
  coord_fixed() +
  labs(title = "ROC Curve", x = "1 - Specificity (FPR)", y = "Sensitivity (TPR)")
    }>,
    deserializer = ^ipc
  )

  -- Render Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

-- Materialize
populate_pipeline(p, build = true, verbose=1)
pipeline_copy()

-- Node correctness assertions (key nodes in the XGBoost pipeline)
r_cm = read_node(p.confusion_matrix)
assert(type(r_cm.error) == "NA", "confusion_matrix (R yardstick) should succeed")

r_acc = read_node(p.accuracy)
assert(type(r_acc.error) == "NA", "accuracy (Python sk-learn) should succeed")

print("✓ r_py_xgboost_t: all assertions passed")

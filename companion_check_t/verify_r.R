library(tlang)
# data_node was serialized as CSV, so we need to tell read_node to use read.csv
df <- read_node("data_node", deserializer = read.csv)
print(df)
if (nrow(df) == 3) {
  cat("R verification successful\n")
} else {
  stop("R verification failed")
}

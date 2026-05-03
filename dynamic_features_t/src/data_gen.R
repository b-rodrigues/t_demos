library(readr)
set.seed(42)
df <- data.frame(
    id = 1:100,
    age = runif(100, 18, 80),
    income = runif(100, 20000, 150000),
    spending = runif(100, 50, 5000),
    category = sample(c("Tech", "Finance", "Retail"), 100, replace = TRUE)
)
write_csv(df, "raw_data.csv")

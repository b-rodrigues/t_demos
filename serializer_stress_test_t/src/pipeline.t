import colcraft
import dataframe
import stats

p = pipeline {
    -- Generate 1M rows in R
    large_data = node(
        command = <{
            n <- 1000000
            cat("Generating", n, "rows in R...\n")
            data.frame(
                id = 1:n,
                val_f = rnorm(n),
                val_i = as.integer(runif(n, 0, 100)),
                label = sample(LETTERS, n, replace = TRUE),
                logic = sample(c(TRUE, FALSE), n, replace = TRUE)
            )
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- Process in T
    summarized = node(
        command = large_data 
              |> group_by($label)
              |> summarize(
                n = n(),
                avg_f = mean($val_f),
                sum_i = sum($val_i)
              ),
        runtime = T
    )
}

print("Starting 1M row serializer stress test...")
start_time = now()
populate_pipeline(p, build = true, verbose = 1)
end_time = now()

res = read_node("summarized")
print("Summarized result (by Letter):")
print(res)

print("Pipeline execution took approximately:")
-- Note: T period subtraction and printing
print(end_time - start_time)

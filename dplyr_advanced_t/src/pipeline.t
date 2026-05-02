import colcraft
import dataframe
import stats
import "src/across.t"

p = pipeline {
    -- R node generating raw data
    raw_data = node(
        command = <{
            set.seed(42)
            df <- data.frame(
                id = 1:10,
                val_a = runif(10, 10, 20),
                val_b = runif(10, 100, 200),
                val_c = runif(10, 1, 2),
                tag = sample(c("X", "Y"), 10, replace = TRUE),
                stringsAsFactors = FALSE
            )
            df
        }>,
        runtime = R,
        serializer = ^arrow
    );

    -- R node performing transformations
    r_across = node(
        raw_data,
        command = <{
            library(dplyr)
            raw_data %>%
                mutate(across(starts_with("val"), ~ .x / 10)) %>%
                relocate(tag, .before = id)
        }>,
        runtime = R,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- T node performing the SAME transformations as R
    t_across_parity = node(
        raw_data,
        command = <{
            raw_data 
              |> mutate_across(["val_a", "val_b", "val_c"], \(x) x / 10.0) 
              |> relocate($tag, .before = $id)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    );

    -- Parity check node
    parity_check = node(
        [r_across, t_across_parity],
        command = <{
            assert(identical(r_across, t_across_parity), "R and T across() results are NOT identical!")
            print("✓ Parity check passed: R and T across() implementations matched perfectly.")
            true
        }>,
        runtime = T,
        deserializer = [r_across: ^arrow, t_across_parity: ^arrow]
    );


    -- T node using summarize_across for extra features
    t_summary = node(
        raw_data,
        command = <{
            raw_data |> summarize_across(["val_a", "val_b", "val_c"], mean)
        }>,
        runtime = T,
        deserializer = ^arrow,
        serializer = ^arrow
    )
}


print("Running Advanced Dplyr (across, relocate) vs T-Lang pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node("t_across_parity")
print("T-Lang across() result preview:")
glimpse(res)

print("T-Lang summarize_across() result:")
res_sum = read_node("t_summary")
print(res_sum)

parity = read_node("parity_check")
print("Parity Check Result:")
print(parity)


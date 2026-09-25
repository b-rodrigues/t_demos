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
        serializer = ^ipc
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
        deserializer = ^ipc,
        serializer = ^ipc
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
        deserializer = ^ipc,
        serializer = ^ipc
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
        deserializer = [r_across: ^ipc, t_across_parity: ^ipc]
    );


    -- T node using summarize_across for extra features
    t_summary = node(
        raw_data,
        command = <{
            raw_data |> summarize_across(["val_a", "val_b", "val_c"], mean)
        }>,
        runtime = T,
        deserializer = ^ipc,
        serializer = ^ipc
    )
}


print("Running Advanced Dplyr (across, relocate) vs T-Lang pipeline...")
populate_pipeline(p, build = true, verbose = 1)

res = read_node(p.t_across_parity)
print("T-Lang across() result preview:")
glimpse(res)

print("T-Lang summarize_across() result:")
res_sum = read_node(p.t_summary)
print(res_sum)

parity = read_node(p.parity_check)
print("Parity Check Result:")
print(parity)

-- 0.55.1 verbs (pure T, no extra Nix nodes)
left = to_dataframe([[id: 1, x: "a"], [id: 2, x: "b"]])
right = to_dataframe([[id: 2, y: "two"], [id: 3, y: "three"]])
assert(nrow(right_join(left, right, by = $id)) == 2, "right_join keeps every row from the right table")
assert(nrow(cross_join(left, right)) == 4, "cross_join returns the cartesian product")
assert(sum(coalesce([1, NA, 3], [10, 20, 30])) == 24, "coalesce returns the first non-NA value per position")
assert(n_distinct([1, 1, NA, 2], na_rm = true) == 2, "n_distinct na_rm excludes NA values")
print("✓ dplyr_advanced_t: 0.55.1 verb assertions passed")


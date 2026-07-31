# Shared R helper functions merged into R nodes via set_pipeline_global_options.
# This file is intentionally minimal: its presence in the node sandbox is what matters.

total_per_group <- function(df, g) {
  df |>
    dplyr::group_by({{ g }}) |>
    dplyr::summarise(total = sum(value))
}

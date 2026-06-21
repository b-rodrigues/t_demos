library(ggplot2)

plot_spirographs <- function(points) {
  label <- "fixed_radius = %s, cycling_radius = %s"
  points$parameters <- sprintf(label, points$fixed_radius, points$cycling_radius)
  ggplot(points) +
    geom_point(aes(x = x, y = y, color = parameters), size = 0.1) +
    facet_wrap(~parameters) +
    theme_gray(16) +
    guides(color = "none")
}

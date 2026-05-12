p = pipeline {
    raw_data = jln(
        command = <{
            using DataFrames

            DataFrame(
                x = 1:10,
                y = (1:10).^2,
                group = repeat(["odd", "even"], 5)
            )
        }>,
        serializer = ^csv
    )

    tidierplots_node = jln(
        command = <{
            using TidierPlots, CairoMakie

            TidierPlots_set("plot_show", false)
            TidierPlots_set("plot_log", false)

            ggplot(raw_data) +
                geom_line(aes(x = :x, y = :y, color = :group)) +
                geom_point(aes(x = :x, y = :y, color = :group)) +
                labs(title = "TidierPlots Plot", x = "Input X", y = "Squared Y")
        }>,
        deserializer = ^csv
    )

    makie_node = jln(
        command = <{
            using CairoMakie

            lines(
                raw_data.x,
                raw_data.y;
                label = "Squared Y",
                color = :steelblue,
                axis = (; xlabel = "Input X", ylabel = "Squared Y", title = "Makie Plot"),
                figure = (; size = (800, 600))
            )
        }>,
        deserializer = ^csv
    )

    plots_node = jln(
        command = <{
            using Plots

            plot(
                raw_data.x,
                raw_data.y;
                seriestype = :scatterpath,
                markersize = 5,
                color = :darkorange,
                label = "Squared Y",
                title = "Plots.jl Plot",
                xlabel = "Input X",
                ylabel = "Squared Y"
            )
        }>,
        deserializer = ^csv
    )
}

print("Building Julia plotting demo pipeline...")
res = build_pipeline(p, verbose = 1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.\n")

    print("--- Testing show_plot() with Julia plotting libraries ---")

    print("Rendering TidierPlots...")
    tidierplots_path = show_plot(tidierplots_node)
    print("Saved to: ", tidierplots_path)

    print("Rendering Makie...")
    makie_path = show_plot(makie_node)
    print("Saved to: ", makie_path)

    print("Rendering Plots.jl...")
    plots_path = show_plot(plots_node)
    print("Saved to: ", plots_path)

    print("\n--- Metadata check ---")
    tidierplots_meta = read_node("tidierplots_node")
    print("TidierPlots class: ", tidierplots_meta.class)

    makie_meta = read_node("makie_node")
    print("Makie class: ", makie_meta.class)

    plots_meta = read_node("plots_node")
    print("Plots.jl class: ", plots_meta.class)
}

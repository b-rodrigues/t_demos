p = pipeline {
    data_node = node(
        command = <{
            data.frame(x = 1:10, y = (1:10)^2)
        }>,
        runtime = R,
        serializer = ^arrow
    )

    ggplot_node = node(
        command = <{
            library(ggplot2)
            ggplot(data_node, aes(x = x, y = y)) +
                geom_point() +
                geom_line() +
                labs(title = "R Plot", x = "Input X", y = "Squared Y")
        }>,
        runtime = R,
        dependencies = ["data_node"]
    )

    matplotlib_node = node(
        command = <{
import matplotlib.pyplot as plt
import pandas as pd

fig, ax = plt.subplots()
ax.plot(data_node['x'], data_node['y'], 'ro-')
ax.set_title("Python Plot")
ax.set_xlabel("Input X")
ax.set_ylabel("Squared Y")
fig
        }>,
        runtime = Python,
        dependencies = ["data_node"]
    )
}

print("Building Plotting Demo pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.\n")
    
    g = read_node("ggplot_node")
    m = read_node("matplotlib_node")
    
    print("--- ggplot2 Metadata ---")
    print("Class: ", g.class)
    print("Backend: ", g.backend)
    print("Title: ", g.title)
    print("Labels: ", g.labels)
    print("Layers: ", g.layers)
    print("Mapping: ", g.mapping)
    
    print("\n--- matplotlib Metadata ---")
    print("Class: ", m.class)
    print("Backend: ", m.backend)
    print("Title: ", m.title)
    print("Labels: ", m.labels)
    print("Layers: ", m.layers)
}

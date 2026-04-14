p = pipeline {
    data_node = node(
        command = <{
            data.frame(x = 1:10, y = (1:10)^2)
        }>,
        runtime = R,
        serializer = ^csv
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
        deserializer = ^csv
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
matplotlib_node = fig
        }>,
        runtime = Python,
        deserializer = ^csv
    )

    seaborn_node = node(
        command = <{
import seaborn as sns
import matplotlib.pyplot as plt
import pandas as pd

df = pd.DataFrame(data_node)
# Get the Axes object from seaborn
plt.figure()
plot = sns.lineplot(x='x', y='y', data=df)
plot.set_title("Seaborn Plot")
seaborn_node = plot
        }>,
        runtime = Python,
        deserializer = ^csv
    )

    plotly_node = node(
        command = <{
import plotly.express as px
import pandas as pd

df = pd.DataFrame(data_node)
fig = px.line(df, x='x', y='y', title="Plotly Plot")
plotly_node = fig
        }>,
        runtime = Python,
        deserializer = ^csv
    )

    altair_node = node(
        command = <{
import altair as alt
import pandas as pd

df = pd.DataFrame(data_node)
chart = alt.Chart(df).mark_line().encode(x='x', y='y').properties(title="Altair Plot")
altair_node = chart
        }>,
        runtime = Python,
        deserializer = ^csv
    )

    plotnine_node = node(
        command = <{
from plotnine import ggplot, aes, geom_line, labs
import pandas as pd

df = pd.DataFrame(data_node)
p = (ggplot(df, aes(x='x', y='y')) 
     + geom_line() 
     + labs(title="Plotnine Plot"))
plotnine_node = p
        }>,
        runtime = Python,
        deserializer = ^csv
    )
}

print("Building Plotting Demo pipeline...")
res = build_pipeline(p, verbose=1)

if (is_error(res)) {
    print("Pipeline build failed:")
    print(res)
} else {
    print("Build successful.\n")
    
    print("--- Testing show_plot (renders to _pipeline/ and opens viewer) ---")
    -- In CI, show_plot will render the PNGs but opening the viewer might fail or be ignored.
    -- The PNGs will be saved in _pipeline/
    
    print("Rendering ggplot2...")
    g_path = show_plot(ggplot_node)
    print("Saved to: ", g_path)
    
    print("Rendering matplotlib...")
    m_path = show_plot(matplotlib_node)
    print("Saved to: ", m_path)
    
    print("Rendering seaborn...")
    s_path = show_plot(seaborn_node)
    print("Saved to: ", s_path)
    
    print("Rendering plotly...")
    pl_path = show_plot(plotly_node)
    print("Saved to: ", pl_path)
    
    print("Rendering altair...")
    a_path = show_plot(altair_node)
    print("Saved to: ", a_path)
    
    print("Rendering plotnine...")
    pn_path = show_plot(plotnine_node)
    print("Saved to: ", pn_path)
    
    print("\n--- Metadata check ---")
    g = read_node("ggplot_node")
    print("ggplot2 Title: ", g.title)
    
    m = read_node("matplotlib_node")
    print("matplotlib Title: ", m.title)
    
    s = read_node("seaborn_node")
    print("seaborn Class: ", s.class)
    
    pl = read_node("plotly_node")
    print("plotly Class: ", pl.class)
}

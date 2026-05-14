
{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake (toString "/home/runner/work/t_demos/t_demos/plotting_pipeline_t");
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  toml = if builtins.pathExists "/home/runner/work/t_demos/t_demos/plotting_pipeline_t/tproject.toml" then builtins.fromTOML (builtins.readFile "/home/runner/work/t_demos/t_demos/plotting_pipeline_t/tproject.toml") else {};
  rPackagesList = (toml.r-dependencies or {}).packages or [];
  r-env = pkgs.rWrapper.override {
    packages = builtins.map (p: pkgs.rPackages.${p}) rPackagesList;
  };
  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = pyDeps.version or "python3";
  pyPackagesList = pyDeps.packages or [];
  py-env = pkgs.${pyVersion}.withPackages (ps: builtins.map (p: ps.${p}) pyPackagesList);
  artifact = builtins.path { name = "plot-artifact"; path = "/nix/store/ynzayd2g038kqdmq5cqq1xg959qpk1qk-pipeline_output/seaborn_node/artifact"; };
in
pkgs.stdenv.mkDerivation {
  name = "show-plot-render";
  dontUnpack = true;
  buildInputs = [ py-env ];
  MPLCONFIGDIR = ".";
  ARTIFACT_PATH = "${artifact}";
  buildCommand = ''
    mkdir -p "$out"
    export out="$out"
    cat <<'EOF' > "$TMPDIR/render_plot.py"

import os
artifact_path = os.environ["ARTIFACT_PATH"]
output_path = os.path.join(os.environ["out"], "plot.png")

def deserialize(path):
    # Try standard pickle first for maximum compatibility
    try:
        import pickle
        with open(path, "rb") as f:
            return pickle.load(f)
    except Exception:
        pass

    # Try dill next for environments that serialized with dill.
    try:
        import dill
        with open(path, "rb") as f:
            return dill.load(f)
    except Exception:
        pass
    
    # Try cloudpickle as last resort
    import cloudpickle as cp
    with open(path, "rb") as f:
        return cp.load(f)

plot_obj = deserialize(artifact_path)

try:
    import matplotlib
except (ImportError, ModuleNotFoundError) as exc:
    raise ImportError("show_plot requires `matplotlib` in [py-dependencies].packages.") from exc

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.figure import Figure as MatplotlibFigure
from matplotlib.axes import Axes as MatplotlibAxes

try:
    from plotnine.ggplot import ggplot as PlotnineGGPlot
except (ImportError, ModuleNotFoundError):
    PlotnineGGPlot = None

if PlotnineGGPlot is not None and isinstance(plot_obj, PlotnineGGPlot):
    fig = plot_obj.draw()
    fig.savefig(output_path, dpi=144, bbox_inches="tight")
    plt.close(fig)
# Axes is checked before Figure so single-axes objects render their parent
# figure directly without changing the public show_plot contract.
elif isinstance(plot_obj, MatplotlibAxes):
    plot_obj.figure.savefig(output_path, dpi=144, bbox_inches="tight")
elif isinstance(plot_obj, MatplotlibFigure):
    plot_obj.savefig(output_path, dpi=144, bbox_inches="tight")
elif type(plot_obj).__module__.startswith("seaborn"):
    fig = getattr(plot_obj, "fig", getattr(plot_obj, "figure", None))
    if fig:
        fig.savefig(output_path, dpi=144, bbox_inches="tight")
    else:
        raise TypeError(f"show_plot failed to extract figure from seaborn object of type {type(plot_obj).__name__}")
elif type(plot_obj).__module__.startswith("plotly"):
    try:
        import plotly.io as pio
        # static image export requires 'kaleido'
        pio.write_image(plot_obj, output_path, format="png")
    except Exception as exc:
        raise RuntimeError(f"show_plot: plotly renderer failed. Ensure 'kaleido' is in [py-dependencies].packages. Error: {str(exc)}")
elif type(plot_obj).__module__.startswith("altair"):
    try:
        import vl_convert as vlc
        spec = plot_obj.to_json()
        png_data = vlc.vegalite_to_png(vl_spec=spec)
        with open(output_path, "wb") as f:
            f.write(png_data)
    except Exception as exc:
        try:
             plot_obj.save(output_path)
        except Exception:
             raise RuntimeError(f"show_plot: altair renderer failed. Ensure 'vl-convert-python' or 'altair_saver' is in [py-dependencies].packages. Error: {str(exc)}")
else:
    raise TypeError("show_plot currently supports matplotlib Figure/Axes, plotnine ggplot, seaborn Grid, plotly Figure, and altair Chart objects for Python nodes.")

EOF
    python "$TMPDIR/render_plot.py"
  '';
}

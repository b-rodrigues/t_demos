
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
  artifact = builtins.path { name = "plot-artifact"; path = "/nix/store/ynzayd2g038kqdmq5cqq1xg959qpk1qk-pipeline_output/ggplot_node/artifact"; };
in
pkgs.stdenv.mkDerivation {
  name = "show-plot-render";
  dontUnpack = true;
  buildInputs = [ r-env ];
  MPLCONFIGDIR = ".";
  ARTIFACT_PATH = "${artifact}";
  buildCommand = ''
    mkdir -p "$out"
    export out="$out"
    cat <<'EOF' > "$TMPDIR/render_plot.R"

plot_obj <- readRDS(Sys.getenv("ARTIFACT_PATH"))
if (!inherits(plot_obj, "ggplot")) {
  stop("show_plot currently supports ggplot objects for R nodes.")
}
if (!requireNamespace("ggplot2", quietly = TRUE)) {
  stop("show_plot requires `ggplot2` in [r-dependencies].packages.")
}
ggplot2::ggsave(
  filename = file.path(Sys.getenv("out"), "plot.png"),
  plot = plot_obj,
  width = 8,
  height = 6,
  dpi = 144,
  units = "in"
)

EOF
    Rscript "$TMPDIR/render_plot.R"
  '';
}

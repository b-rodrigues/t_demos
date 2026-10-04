
{ system ? builtins.currentSystem }:
let
  # mkNodeEnv: build a runtime environment from an arbitrary flake path.
  # R and Python serializer packages (jsonlite, arrow, deepdiff, etc.) are
  # resolved from the flake's nixpkgs automatically -- not from tproject.toml.
  # Julia package lists still come from the project's tproject.toml.
  # The flake provides nixpkgs version, t-lang version, and R/Python/Julia versions.
  # Each component is resolved independently: if the flake provides `t-lang` (or
  # has the relevant package), it is used; otherwise it falls back to the
  # project-level binding. This allows e.g. an R-only flake (like jbedo/rshells)
  # to provide R packages while T serialization infrastructure comes from the project.
  # Note: toString is required to convert the path to a string
  # that builtins.getFlake accepts.
  mkNodeEnv = flakePath:
    let
      flake = builtins.getFlake flakePath;
      pkgs   = if (builtins.hasAttr "legacyPackages" flake && builtins.hasAttr system flake.legacyPackages) 
               then flake.legacyPackages.${system} 
               else flake.inputs.nixpkgs.legacyPackages.${system};
      stdenv = pkgs.stdenv;
      tlangPkgSet = let
        pkgFlake = flake.inputs.t-lang or flake;
      in if builtins.hasAttr "packages" pkgFlake && builtins.hasAttr system pkgFlake.packages then
        pkgFlake.packages.${system}
      else {};
      tBin   = if tlangPkgSet ? default then tlangPkgSet.default else projectTBin;
      r-env = pkgs.rWrapper.override {
        packages = (builtins.map (p: pkgs.rPackages.${builtins.replaceStrings ["."] ["_"] p}) rSerializerPackages) ++ (if tlangPkgSet ? tlang-r then [ tlangPkgSet.tlang-r ] else []);
      };
      py-env = if tlangPkgSet ? py-env then tlangPkgSet.py-env
               else let pyInterp = if builtins.hasAttr pyVersion pkgs then pkgs.${pyVersion} else pkgs.python3;
               in pyInterp.withPackages (ps: [ ps.deepdiff ] ++ (builtins.map (p: ps.${p}) pySerializerPackages));
      juliaPkg = let
        juliaBase = pkgs.${juliaPackageName};
      in if juliaPackagesList == [] then juliaBase else juliaBase.withPackages juliaPackagesList;
      tlangJl = if tlangPkgSet ? tlang-julia-path then tlangPkgSet.tlang-julia-path else projectTlangJl;
    in { inherit tBin pkgs stdenv tlangPkgSet r-env py-env juliaPkg tlangJl; };

  # Pull exact pinned inputs from the project flake.
  # The flake.lock guarantees reproducibility.
  projectFlake  = builtins.getFlake (toString ../.);
  projectPkgs   = if (builtins.hasAttr "legacyPackages" projectFlake && builtins.hasAttr system projectFlake.legacyPackages) 
           then projectFlake.legacyPackages.${system} 
           else projectFlake.inputs.nixpkgs.legacyPackages.${system};
  projectTBin   = let
             base = (projectFlake.inputs.t-lang or projectFlake).packages.${system}.default;
           in if builtins.pathExists ../dune-project then
             base.overrideAttrs (old: { src = sources; })
           else base;
  projectStdenv = projectPkgs.stdenv;
  projectTlangPkgSet = let
    pkgFlake = projectFlake.inputs.t-lang or projectFlake;
  in if builtins.hasAttr "packages" pkgFlake && builtins.hasAttr system pkgFlake.packages then
    pkgFlake.packages.${system}
  else {};
  projectREnv = projectPkgs.rWrapper.override {
    packages = (builtins.map (p: projectPkgs.rPackages.${builtins.replaceStrings ["."] ["_"] p}) rPackagesList) ++ (builtins.map (p: projectPkgs.rPackages.${builtins.replaceStrings ["."] ["_"] p}) rRenvPackagesList) ++ rGitPkgsList ++ (builtins.map (p: projectPkgs.rPackages.${builtins.replaceStrings ["."] ["_"] p}) rSerializerPackages) ++ [ projectTlangPkgSet.tlang-r ];
  };
  projectPyEnv =
    if pyResolver == "uv" then
      let
        pyWorkspace = projectFlake.inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ../. + "/${pyWorkspaceDir}"; };
        pyOverlay = pyWorkspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
        pySet = (projectPkgs.callPackage projectFlake.inputs.pyproject-nix.build.packages { python = projectPkgs.${pyVersion}; }).overrideScope (projectPkgs.lib.composeManyExtensions [ pyOverlay projectFlake.inputs.pyproject-build-systems.overlays.default ]);
      in pySet.mkVirtualEnv "t-python-uv-env" pyWorkspace.deps.default
    else
      projectPkgs.${pyVersion}.withPackages (ps: [ ps.deepdiff ] ++ (builtins.map (p: ps.${p}) pySerializerPackages) ++ (builtins.map (p: ps.${p}) pyPackagesList));
  projectJuliaPkg = let
    juliaBase = projectPkgs.${juliaPackageName};
  in if juliaPackagesList == [] then juliaBase else juliaBase.withPackages juliaPackagesList;
  projectTlangJl = projectTlangPkgSet.tlang-julia-path;

  # Backward-compat aliases (used by nodes without a custom flake)
  flake  = projectFlake;
  pkgs   = projectPkgs;
  tBin   = projectTBin;
  stdenv = projectStdenv;
  tlangPkgSet = projectTlangPkgSet;
  "r-env" = projectREnv;
  "py-env" = projectPyEnv;
  juliaPkg = projectJuliaPkg;
  tlangJl = projectTlangJl;

  # Filter out _pipeline/, .git/, and other non-source directories.
  # pipeline-output/ is the default target of pipeline_copy(): it must stay
  # out of `sources`, otherwise each copy changes the source hash and every
  # node rebuilds on the next run.
  sources = builtins.filterSource
    (path: type:
      let baseName = builtins.baseNameOf path;
      in !(baseName == "_pipeline" || baseName == ".git" || baseName == ".direnv" || baseName == "_build" || baseName == "pipeline-output"))
    ../.;

  toml = if builtins.pathExists ../tproject.toml then builtins.fromTOML (builtins.readFile ../tproject.toml) else {};
  
    rSerializerPackages = [  ];
    pySerializerPackages = [  ];
  rPackagesList = (toml.r-dependencies or {}).packages or [];
    rRenvPackagesList = [  ];
    rGitPkgSet = {};
  rGitPkgsList = builtins.attrValues rGitPkgSet;
  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = "python312";
  pyResolver = pyDeps.resolver or "nixpkgs";
  pyWorkspaceDir = pyDeps.workspace or "python";
  pyPackagesList = if pyResolver == "uv" then [] else pyDeps.packages or [];
  juliaDeps = toml.jl-dependencies or {};
  juliaVersion = juliaDeps.version or "lts";
  juliaPackageName = if juliaVersion == "lts" then "julia-lts" else "julia_" + (builtins.replaceStrings ["."] ["_"] juliaVersion);
  juliaPackagesList = (juliaDeps.packages or []) ++ [ "DataFrames" "CSV" "StatsModels" "JSON" "JLD2" ];

  # Additional Tools & LaTeX
  additionalTools = (toml.additional-tools or {}).packages or [];
  latexPkgs = (toml.latex or {}).packages or [];
  
  latexCombined = if latexPkgs == [] then null 
                  else pkgs.texlive.combine (builtins.listToAttrs (builtins.map (name: { name = name; value = pkgs.texlive.${name}; }) (["scheme-small"] ++ latexPkgs)));
                  
  globalBuildInputs = (builtins.map (p: pkgs.${p}) (builtins.filter (p: p != "atelier") additionalTools))
                      ++ (if latexCombined == null then [] else [ latexCombined ]);

  # Per-node flake environments

in
rec {

  a = stdenv.mkDerivation {
    name = "a";
    buildInputs = [ tBin py-env ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.py

EOF
      cat << 'EOF' >> node_script.py

import json
import os
import sys
import traceback

def py_write_error(msg, path):
    if isinstance(msg, dict) and msg.get("type") == "VError":
        err_info = msg
    else:
        traceback_text = msg if isinstance(msg, str) else str(msg)
        message_lines = [line for line in traceback_text.splitlines() if line.strip()]
        err_info = {
            "type": "VError",
            "code": "RuntimeError",
            "message": message_lines[-1].strip() if message_lines else traceback_text,
            "na_count": 0,
            "context": {
                "runtime_traceback": traceback_text,
                "node_status": "errored"
            },
            "location": None
        }
    with open(path, "w") as f:
        json.dump(err_info, f)
    with open(os.path.join(os.path.dirname(path), "class"), "w") as f:
        f.write("VError")

def py_is_error(obj):
    return isinstance(obj, dict) and obj.get("type") == "VError"

def py_write_warnings(warnings_list, path):
    cleaned = [str(w.message if hasattr(w, "message") else w) for w in warnings_list]
    if cleaned:
        with open(path, "w") as f:
            json.dump(cleaned, f)

EOF
      cat << 'EOF' >> node_script.py

import json

def _py_clean_mapping_value(value):
    text = str(value)
    if text.startswith("after_stat(") or text.startswith("stage("):
        return text
    if text.startswith("'") and text.endswith("'"):
        return text[1:-1]
    return text

def _py_compact_dict(entries):
    return {key: value for key, value in entries.items() if value not in (None, "", [], {})}

def _py_plotnine_mapping(mapping):
    if mapping is None:
        return {}
    return _py_compact_dict({key: _py_clean_mapping_value(value) for key, value in mapping.items()})

def _py_plotnine_labels(obj):
    labels_obj = getattr(obj, "labels", None)
    if labels_obj is None:
        return {}
    return _py_compact_dict({
        "title": getattr(labels_obj, "title", None),
        "subtitle": getattr(labels_obj, "subtitle", None),
        "caption": getattr(labels_obj, "caption", None),
        "x": getattr(labels_obj, "x", None),
        "y": getattr(labels_obj, "y", None),
        "color": getattr(labels_obj, "color", None),
        "fill": getattr(labels_obj, "fill", None),
    })

def _py_plotnine_layers(obj):
    layers = []
    for layer in getattr(obj, "layers", []) or []:
        geom = getattr(layer, "geom", None)
        geom_name = type(geom).__name__ if geom is not None else None
        if geom_name:
            layers.append(geom_name.replace("geom_", ""))
    return layers

def _py_matplotlib_layers(ax):
    layers = []
    if getattr(ax, "lines", None):
        layers.extend(type(line).__name__ for line in ax.lines)
    if getattr(ax, "collections", None):
        layers.extend(type(collection).__name__ for collection in ax.collections)
    if getattr(ax, "patches", None):
        layers.extend(type(patch).__name__ for patch in ax.patches if type(patch).__name__ != "Spine")
    if getattr(ax, "images", None):
        layers.extend(type(image).__name__ for image in ax.images)
    deduped = []
    for layer in layers:
        if layer not in deduped:
            deduped.append(layer)
    return deduped

def py_extract_plot_metadata(obj):
    try:
        from plotnine.ggplot import ggplot as PlotnineGGPlot
    except Exception:
        PlotnineGGPlot = None
    if PlotnineGGPlot is not None and isinstance(obj, PlotnineGGPlot):
        labels = _py_plotnine_labels(obj)
        return {
            "class": "plotnine",
            "backend": "Python",
            "title": labels.get("title"),
            "mapping": _py_plotnine_mapping(getattr(obj, "mapping", None)),
            "labels": labels,
            "layers": _py_plotnine_layers(obj),
            "_display_keys": ["class", "backend", "title", "mapping", "labels", "layers"],
        }

    try:
        from matplotlib.figure import Figure as MatplotlibFigure
        from matplotlib.axes import Axes as MatplotlibAxes
    except Exception:
        MatplotlibFigure = ()
        MatplotlibAxes = ()

    figure = None
    axes = None
    # Default title; backend-specific extraction below can replace it, and the
    # later figure/axes fallback only runs when the title is still empty.
    title = None
    viz_class = "matplotlib"

    # Seaborn support
    try:
        # Check by module name to avoid hard dependency on seaborn in the extractor
        obj_type = type(obj)
        if obj_type.__module__.startswith("seaborn"):
            viz_class = "seaborn"
            if hasattr(obj, "fig"):
                figure = obj.fig
            elif hasattr(obj, "figure"):
                figure = obj.figure
            if figure and not axes:
                axes = figure.axes[0] if getattr(figure, "axes", None) else None
    except Exception:
        pass

    # Plotly support
    try:
        obj_type = type(obj)
        if obj_type.__module__.startswith("plotly"):
            viz_class = "plotly"
            if hasattr(obj, "layout") and obj.layout.title:
                t = obj.layout.title
                if hasattr(t, "text"):
                    title = t.text
                elif isinstance(t, str):
                    title = t
    except Exception:
        pass

    # Altair support
    try:
        if type(obj).__module__.startswith("altair"):
            viz_class = "altair"
            if hasattr(obj, "title") and obj.title:
                title = str(obj.title)
    except Exception:
        pass

    if figure is None and axes is None:
        if MatplotlibFigure and isinstance(obj, MatplotlibFigure):
            figure = obj
            axes = obj.axes[0] if getattr(obj, "axes", None) else None
        elif MatplotlibAxes and isinstance(obj, MatplotlibAxes):
            axes = obj
            figure = getattr(obj, "figure", None)
    if figure is None and axes is None:
        if viz_class not in ["plotly", "altair"]:
            return None
    else:
        suptitle = getattr(figure, "_suptitle", None) if figure is not None else None
        if title is None and suptitle is not None:
            text = suptitle.get_text()
            if text:
                title = text
        if title is None and axes is not None:
            text = axes.get_title()
            if text:
                title = text

    labels = _py_compact_dict({
        "title": title,
        "x": axes.get_xlabel() if axes is not None else None,
        "y": axes.get_ylabel() if axes is not None else None,
    })
    return {
        "class": viz_class,
        "backend": "Python",
        "title": title,
        "mapping": {},
        "labels": labels,
        "layers": _py_matplotlib_layers(axes) if axes is not None else [],
        "_display_keys": ["class", "backend", "title", "mapping", "labels", "layers"],
    }

def py_visual_class(obj):
    metadata = py_extract_plot_metadata(obj)
    if metadata is not None:
        return metadata.get("class", "matplotlib")
    return type(obj).__name__

def py_save_viz_metadata(obj, path):
    metadata = py_extract_plot_metadata(obj)
    if metadata is not None:
        with open(path, "w") as f:
            json.dump(metadata, f)

EOF
      cat << 'EOF' >> node_script.py

import json
def py_write_json(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f)
def py_read_json(path):
    with open(path) as f:
        return json.load(f)

EOF





      cat << 'EOF' >> node_script.py

import os
import pickle

def serialize(obj, path):
    # Use standard pickle by default.
    # We only switch to cloudpickle/dill if we detect a complex plot object
    # that standard pickle likely cannot handle (due to lambdas/internal state).
    use_enhanced = False
    try:
        mod = type(obj).__module__
        if mod.startswith(("matplotlib", "seaborn", "plotly", "altair", "plotnine")):
            use_enhanced = True
    except Exception:
        pass

    if use_enhanced:
        try:
            import dill
            with open(path, "wb") as f:
                dill.dump(obj, f)
            return
        except Exception:
            pass
        try:
            import cloudpickle as cp
            with open(path, "wb") as f:
                cp.dump(obj, f)
            return
        except Exception:
            pass

    with open(path, "wb") as f:
        pickle.dump(obj, f)

def deserialize(path):
    # Try standard pickle first for maximum compatibility
    try:
        import pickle
        with open(path, "rb") as f:
            return pickle.load(f)
    except Exception:
        pass

    # Try dill next (more robust for Bokeh)
    try:
        import dill
        with open(path, "rb") as f:
            return dill.load(f)
    except Exception:
        pass
    
    # Try cloudpickle as last resort
    try:
        import cloudpickle as cp
        with open(path, "rb") as f:
            return cp.load(f)
    except Exception:
        pass
    
    # Final chance (if cloudpickle import failed but we didn't return)
    with open(path, "rb") as f:
        return pickle.load(f)

EOF


      cat <<'EOF' >> node_script.py
import pandas as pd
EOF



      echo "def __node_runner():" >> node_script.py
      cat <<'EOF' >> node_script.py
    df = pd.read_csv("data/scores.csv")
    return float(df["score"].mean())
EOF
      echo "    return" >> node_script.py
      echo "try:" >> node_script.py
      echo "    import warnings" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      echo "        __node_result = __node_runner()" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_json(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin a projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${a} $out/a
    '';
  };
}

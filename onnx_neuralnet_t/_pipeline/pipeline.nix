
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
    pySerializerPackages = [ "onnxruntime" "skl2onnx" ];
  rPackagesList = (toml.r-dependencies or {}).packages or [];
    rRenvPackagesList = [  ];
    rGitPkgSet = {};
  rGitPkgsList = builtins.attrValues rGitPkgSet;
  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = "python314";
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

  demo_data = stdenv.mkDerivation {
    name = "demo_data";
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
import numpy as np
from sklearn.datasets import make_classification
EOF



      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np
        from sklearn.datasets import make_classification

        feature_names = [f"f{i}" for i in range(10)]

        X, y = make_classification(
            n_samples=200,
            n_features=10,
            n_informative=5,
            random_state=42
        )
        X = X.astype(np.float32)

        test_samples = np.array([
            [np.sin(i) for i in range(10)],
            [np.cos(i) for i in range(10)],
            [0.5 * i for i in range(10)],
        ], dtype=np.float32)

        demo_data = {
            "feature_names": feature_names,
            "training_features": {
                feature_name: X[:, index].astype(np.float32).tolist()
                for index, feature_name in enumerate(feature_names)
            },
            "training_labels": y.astype(np.int64).tolist(),
            "test_features": {
                feature_name: test_samples[:, index].astype(np.float32).tolist()
                for index, feature_name in enumerate(feature_names)
            },
            "test_samples": test_samples.astype(np.float32).tolist(),
        }
EOF
      echo "    __node_result = demo_data" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
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
 

  python_model = stdenv.mkDerivation {
    name = "python_model";
    buildInputs = [ tBin py-env demo_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact

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

def _infer_n_features(model):
    import numpy as np
    if hasattr(model, 'n_features_in_'):
        return int(model.n_features_in_)
    if hasattr(model, 'coef_'):
        c = np.array(model.coef_)
        return c.shape[-1] if c.ndim >= 1 else 1
    if hasattr(model, 'in_features'):
        return int(model.in_features)
    modules = getattr(model, 'modules', None)
    if callable(modules):
        for module in model.modules():
            if hasattr(module, 'in_features'):
                return int(module.in_features)
    raise RuntimeError(
        "Unable to infer ONNX input feature count. "
        "Expected a scikit-learn model (n_features_in_, coef_), "
        "a PyTorch model (in_features, modules), or another model "
        "with explicit feature metadata."
    )

def _make_dummy_input(model):
    import torch
    return torch.randn(1, _infer_n_features(model))

def py_write_onnx(model, path):
    import numpy as np
    try:
        from skl2onnx import convert_sklearn
        from skl2onnx.common.data_types import FloatTensorType
        n_features = _infer_n_features(model)
        initial_types = [("input", FloatTensorType([None, n_features]))]
        onnx_model = convert_sklearn(model, initial_types=initial_types, target_opset=21)
        with open(path, "wb") as f:
            f.write(onnx_model.SerializeToString())
        return path
    except ImportError:
        pass
    try:
        import torch
        dummy = _make_dummy_input(model)
        torch.onnx.export(model, dummy, path, opset_version=17)
        return path
    except ImportError:
        pass
    raise RuntimeError(
        "ONNX export in Python requires 'skl2onnx' (for scikit-learn models) "
        "or 'torch' (for PyTorch models). Add the required package to "
        "[py-dependencies].packages in tproject.toml, run `t update`, and "
        "re-enter `nix develop`."
    )

def py_read_onnx(path):
    try:
        import onnxruntime as rt
        return rt.InferenceSession(path)
    except ImportError:
        raise RuntimeError(
            "ONNX deserialization requires 'onnxruntime'. "
            "Add `onnxruntime` to [py-dependencies].packages in "
            "tproject.toml, run `t update`, and re-enter `nix develop`."
        )

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
import numpy as np
import pandas as pd
from sklearn.neural_network import MLPClassifier
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_demo_data\", \"class\")) and open(os.path.join(\"$T_NODE_demo_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "demo_data = __dep_demo_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np
        import pandas as pd
        from sklearn.neural_network import MLPClassifier

        feature_names = demo_data["feature_names"]
        training_frame = pd.DataFrame(demo_data["training_features"])[feature_names].astype(np.float32)
        training_labels = np.array(demo_data["training_labels"], dtype=np.int64)

        model = MLPClassifier(hidden_layer_sizes=(10, 5), max_iter=1000, random_state=42)
        model.fit(training_frame, training_labels)

        python_model = model
EOF
      echo "    __node_result = python_model" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_onnx(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  python_model_state = stdenv.mkDerivation {
    name = "python_model_state";
    buildInputs = [ tBin py-env demo_data python_model ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    T_NODE_python_model = python_model;
    T_INPUT_python_model = "${python_model}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact
      export T_NODE_python_model=${python_model}
      export T_INPUT_python_model=${python_model}/artifact

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

def _infer_n_features(model):
    import numpy as np
    if hasattr(model, 'n_features_in_'):
        return int(model.n_features_in_)
    if hasattr(model, 'coef_'):
        c = np.array(model.coef_)
        return c.shape[-1] if c.ndim >= 1 else 1
    if hasattr(model, 'in_features'):
        return int(model.in_features)
    modules = getattr(model, 'modules', None)
    if callable(modules):
        for module in model.modules():
            if hasattr(module, 'in_features'):
                return int(module.in_features)
    raise RuntimeError(
        "Unable to infer ONNX input feature count. "
        "Expected a scikit-learn model (n_features_in_, coef_), "
        "a PyTorch model (in_features, modules), or another model "
        "with explicit feature metadata."
    )

def _make_dummy_input(model):
    import torch
    return torch.randn(1, _infer_n_features(model))

def py_write_onnx(model, path):
    import numpy as np
    try:
        from skl2onnx import convert_sklearn
        from skl2onnx.common.data_types import FloatTensorType
        n_features = _infer_n_features(model)
        initial_types = [("input", FloatTensorType([None, n_features]))]
        onnx_model = convert_sklearn(model, initial_types=initial_types, target_opset=21)
        with open(path, "wb") as f:
            f.write(onnx_model.SerializeToString())
        return path
    except ImportError:
        pass
    try:
        import torch
        dummy = _make_dummy_input(model)
        torch.onnx.export(model, dummy, path, opset_version=17)
        return path
    except ImportError:
        pass
    raise RuntimeError(
        "ONNX export in Python requires 'skl2onnx' (for scikit-learn models) "
        "or 'torch' (for PyTorch models). Add the required package to "
        "[py-dependencies].packages in tproject.toml, run `t update`, and "
        "re-enter `nix develop`."
    )

def py_read_onnx(path):
    try:
        import onnxruntime as rt
        return rt.InferenceSession(path)
    except ImportError:
        raise RuntimeError(
            "ONNX deserialization requires 'onnxruntime'. "
            "Add `onnxruntime` to [py-dependencies].packages in "
            "tproject.toml, run `t update`, and re-enter `nix develop`."
        )

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
import os
import numpy as np
import pandas as pd
import onnx
import onnxruntime as rt
from onnx import numpy_helper
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_demo_data\", \"class\")) and open(os.path.join(\"$T_NODE_demo_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "if os.path.exists(os.path.join(\"$T_NODE_python_model\", \"class\")) and open(os.path.join(\"$T_NODE_python_model\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_python_model = py_read_json(os.path.join(\"$T_NODE_python_model\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_python_model = py_read_onnx(os.path.join(\"$T_NODE_python_model\", \"artifact\"))" >> node_script.py
      echo "demo_data = __dep_demo_data" >> node_script.py
      echo "python_model = __dep_python_model" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import os
        import numpy as np
        import pandas as pd
        import onnx
        import onnxruntime as rt
        from onnx import numpy_helper

        # The deserializer hands us an InferenceSession, which runs the network
        # but does not expose its weights. The artifact file itself is available
        # through T_INPUT_<dep>, so the `onnx` package can read the graph.
        session = python_model
        input_name = session.get_inputs()[0].name

        model_path = os.environ["T_INPUT_python_model"]
        if os.path.isdir(model_path):
            candidates = [os.path.join(model_path, f) for f in os.listdir(model_path) if f.endswith(".onnx")]
            if len(candidates) != 1:
                raise ValueError(f"Expected one .onnx artifact for python_model, found {candidates}")
            model_path = candidates[0]
        graph = onnx.load(model_path).graph
        tensors = {t.name: numpy_helper.to_array(t) for t in graph.initializer}

        # One (MatMul|Gemm, Add) pair per dense layer, in graph order. Gemm honors
        # transB so weights come out (in, out) like sklearn${"'"}s coefs_.
        weights = []
        biases = []
        have_weight = False
        for node in graph.node:
            if node.op_type in ("MatMul", "Gemm"):
                w = tensors[node.input[1]]
                if node.op_type == "Gemm":
                    trans_b = 0
                    for attr in node.attribute:
                        if attr.name == "transB":
                            trans_b = attr.i
                    if trans_b == 0:
                        w = w.T
                weights.append(np.asarray(w, dtype=np.float32))
                have_weight = True
            elif node.op_type == "Add" and have_weight:
                biases.append(np.asarray(tensors[node.input[1]], dtype=np.float32).reshape(-1))
                have_weight = False

        if len(weights) != 3 or len(biases) != 3:
            raise ValueError(
                f"Expected 3 dense weight matrices and 3 bias vectors, got {len(weights)} weights and {len(biases)} biases"
            )
        for i in range(len(weights) - 1):
            if weights[i].shape[1] != weights[i + 1].shape[0]:
                raise ValueError(f"Layer {i} output {weights[i].shape} does not feed layer {i + 1} {weights[i + 1].shape}")
        for i, (w, b) in enumerate(zip(weights, biases)):
            if b.shape[0] != w.shape[1]:
                raise ValueError(f"Bias {i} length {b.shape} does not match weight columns {w.shape}")

        # Prove the extracted weights ARE the trained network: score training rows
        # both ways and require agreement.
        feature_names = demo_data["feature_names"]
        training_frame = pd.DataFrame(demo_data["training_features"])[feature_names].astype(np.float32)
        check_rows = training_frame.to_numpy(dtype=np.float32)[:5]
        session_probas = session.run(None, {input_name: check_rows})[1]
        activations = check_rows
        for layer_index, (weight_matrix, bias_vector) in enumerate(zip(weights, biases)):
            activations = activations @ weight_matrix + bias_vector
            if layer_index < len(weights) - 1:
                activations = np.maximum(activations, 0.0)
        manual_probas = 1.0 / (1.0 + np.exp(-activations[:, 0]))
        for row_index in range(len(check_rows)):
            if abs(float(session_probas[row_index][1]) - float(manual_probas[row_index])) > 1e-4:
                raise ValueError(f"Extracted weights disagree with the ONNX session on row {row_index}")

        python_model_state = {
            "weights": [weight.astype(np.float64).tolist() for weight in weights],
            "biases": [bias.astype(np.float64).tolist() for bias in biases],
        }
EOF
      echo "    __node_result = python_model_state" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
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
 

  julia_flux_model = stdenv.mkDerivation {
    name = "julia_flux_model";
    buildInputs = [ tBin juliaPkg demo_data python_model_state ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    T_NODE_python_model_state = python_model_state;
    T_INPUT_python_model_state = "${python_model_state}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact
      export T_NODE_python_model_state=${python_model_state}
      export T_INPUT_python_model_state=${python_model_state}/artifact

      cat << EOF > node_script.jl
using DataFrames, CSV, StatsModels, JSON, Logging, Serialization
EOF
      cat << 'EOF' >> node_script.jl

mutable struct TCaptureLogger <: AbstractLogger
    warnings::Vector{String}
end

TCaptureLogger() = TCaptureLogger(String[])

Logging.min_enabled_level(::TCaptureLogger) = Logging.Warn
Logging.shouldlog(::TCaptureLogger, level, _module, group, id) = level >= Logging.Warn
Logging.catch_exceptions(::TCaptureLogger) = false

function Logging.handle_message(logger::TCaptureLogger, level, message, _module, group, id, file, line; kwargs...)
    if level >= Logging.Warn
        push!(logger.warnings, string(message))
    end
end

using Serialization

function jl_error_message(err)
    try
        sprint(showerror, err)
    catch _
        string(err)
    end
end

function jl_error_traceback(err)
    try
        sprint(io -> showerror(io, err, catch_backtrace()))
    catch _
        jl_error_message(err)
    end
end

function jl_write_error(msg, path)
    err_info =
        if msg isa AbstractDict && get(msg, "type", nothing) == "VError"
            msg
        elseif msg isa AbstractDict && get(msg, :type, nothing) == "VError"
            msg
        else
            traceback_text = jl_error_traceback(msg)
            Dict(
                "type" => "VError",
                "code" => "RuntimeError",
                "message" => jl_error_message(msg),
                "na_count" => 0,
                "context" => Dict(
                    "runtime_traceback" => traceback_text,
                    "node_status" => "errored"
                ),
                "location" => nothing
            )
        end
    open(path, "w") do f
        JSON.print(f, err_info)
    end
    open(joinpath(dirname(path), "class"), "w") do f
        write(f, "VError")
    end
end

function jl_is_error(obj)
    (obj isa AbstractDict && get(obj, "type", nothing) == "VError") ||
    (obj isa AbstractDict && get(obj, :type, nothing) == "VError")
end

function jl_write_warnings(warnings_list, path)
    cleaned = [string(w) for w in warnings_list if !isempty(strip(string(w)))]
    if !isempty(cleaned)
        open(path, "w") do f
            JSON.print(f, cleaned)
        end
    end
end

function jl_serialize(obj, path)
    # T-Lang default Julia serialization uses the standard library Serialization package.
    # Note on Julia-version coupling: native Serialization is process-to-process and not stable
    # across major/minor Julia versions. However, in our sandboxed/pinned Nix architecture,
    # any update to the Julia version in the flake changes the Nix store path, which naturally
    # invalidates and rebuilds the cache anyway.
    try
        Serialization.serialize(path, obj)
        return path
    catch err
        err_msg = jl_error_message(err)
        error(
            "T-Lang Julia serialization error: failed to serialize object of type $(typeof(obj)) " *
            "using native Serialization at $(path). Underlying error: $(err_msg)"
        )
    end
end

EOF
      cat << 'EOF' >> node_script.jl

import JSON

function jl_non_empty_string(value)
    try
        !isempty(strip(string(value)))
    catch
        false
    end
end

function jl_string_or_nothing(value)
    value === nothing && return nothing
    raw =
        try
            if applicable(getindex, value)
                value[]
            else
                value
            end
        catch
            value
        end
    try
        text = strip(string(raw))
        isempty(text) ? nothing : text
    catch
        nothing
    end
end

function jl_compact_dict(entries)
    out = Dict{String, Any}()
    for (key, value) in entries
        if value === nothing
            continue
        elseif value isa AbstractString && isempty(strip(value))
            continue
        elseif value isa AbstractVector && isempty(value)
            continue
        elseif value isa AbstractDict && isempty(value)
            continue
        end
        out[string(key)] = value
    end
    out
end

function jl_lookup(container, key)
    container === nothing && return nothing
    candidates =
        if key isa Symbol
            Any[key, String(key)]
        elseif key isa AbstractString
            Any[key, Symbol(key)]
        else
            Any[key]
        end
    for candidate in candidates
        if container isa AbstractDict
            if haskey(container, candidate)
                return container[candidate]
            end
        elseif container isa NamedTuple
            if candidate isa Symbol && candidate in keys(container)
                return getproperty(container, candidate)
            end
        else
            # Try getproperty first
            try
                if candidate isa Symbol && hasproperty(container, candidate)
                    return getproperty(container, candidate)
                end
            catch
            end
            # Fallback to getfield for structs
            try
                if candidate isa Symbol && candidate in fieldnames(typeof(container))
                    return getfield(container, candidate)
                end
            catch
            end
        end
    end
    nothing
end

function jl_type_parts(obj)
    T = typeof(obj)
    (string(parentmodule(T)), string(nameof(T)))
end

function jl_module_matches(module_name, expected)
    module_name == expected || endswith(module_name, "." * expected)
end

function jl_first_string(container, keys)
    for key in keys
        value = jl_string_or_nothing(jl_lookup(container, key))
        if value !== nothing
            return value
        end
    end
    nothing
end

function jl_mapping_to_dict(mapping)
    mapping === nothing && return Dict{String, Any}()
    out = Dict{String, Any}()
    if mapping isa AbstractDict
        for (key, value) in mapping
            cleaned = jl_string_or_nothing(value)
            if cleaned !== nothing
                out[string(key)] = cleaned
            end
        end
        return out
    end
    keys_list =
        try
            collect(propertynames(mapping))
        catch
            Any[]
        end
    for key in keys_list
        cleaned = jl_string_or_nothing(jl_lookup(mapping, key))
        if cleaned !== nothing
            out[string(key)] = cleaned
        end
    end
    out
end

function jl_labels_from_container(container)
    labels = Dict{String, Any}()
    for key in ["title", "subtitle", "caption", "x", "y", "xlabel", "ylabel", "color", "colour", "fill"]
        value = jl_string_or_nothing(jl_lookup(container, key))
        if value !== nothing
            normalized =
                key == "xlabel" ? "x" :
                key == "ylabel" ? "y" :
                key == "colour" ? "color" :
                key
            labels[normalized] = value
        end
    end
    labels
end

function jl_dedup_strings(items)
    seen = Set{String}()
    out = String[]
    for item in items
        value = jl_string_or_nothing(item)
        if value !== nothing && !(value in seen)
            push!(seen, value)
            push!(out, value)
        end
    end
    out
end

function jl_tidierplots_layers(obj)
    layers = jl_lookup(obj, :geoms)
    if layers === nothing; layers = jl_lookup(obj, :layers); end
    if !(layers isa AbstractVector)
        plots = jl_lookup(obj, :plots)
        if plots isa AbstractVector
            return ["GGPlotGrid (" * string(length(plots)) * " plots)"]
        end
        inner = jl_lookup(obj, :plot)
        if inner !== nothing && inner !== obj
            return jl_tidierplots_layers(inner)
        end
        return String[]
    end
    jl_dedup_strings([
        begin
            # Try various fields for the geom name
            geom = jl_lookup(layer, :geom)
            if geom === nothing; geom = jl_lookup(layer, :type); end
            if geom === nothing; geom = jl_lookup(layer, :geom_type); end
            if geom === nothing; geom = jl_lookup(layer, :layer_type); end
            
            name =
                if geom !== nothing
                    string(nameof(typeof(geom)))
                else
                    # Fallback to the layer object's own type
                    string(nameof(typeof(layer)))
                end
            
            # Clean up common suffixes
            name = replace(name, "Geom" => "")
            name = replace(name, "Layer" => "")
            name
        end
        for layer in layers
    ])
end

function jl_plots_primary_subplot(obj)
    subplots = jl_lookup(obj, :subplots)
    if subplots isa AbstractVector && !isempty(subplots)
        return first(subplots)
    end
    nothing
end

function jl_plots_layers(obj, subplot)
    series_sources = Any[]
    for container in (obj, subplot)
        series = jl_lookup(container, :series_list)
        if series isa AbstractVector
            append!(series_sources, series)
        end
    end
    if isempty(series_sources)
        return String[]
    end
    jl_dedup_strings([
        begin
            attrs = jl_lookup(series, :plotattributes)
            seriestype = jl_string_or_nothing(jl_lookup(attrs, :seriestype))
            if seriestype === nothing
                seriestype = jl_string_or_nothing(jl_lookup(series, :seriestype))
            end
            seriestype === nothing ? string(nameof(typeof(series))) : seriestype
        end
        for series in series_sources
    ])
end

function jl_makie_figure(obj)
    module_name, type_name = jl_type_parts(obj)
    if jl_module_matches(module_name, "Makie") || jl_module_matches(module_name, "CairoMakie")
        if type_name == "Figure"
            return obj
        elseif startswith(type_name, "FigureAxisPlot")
            fig = jl_lookup(obj, :figure)
            if fig !== nothing
                return fig
            end
        end
    end
    fig = jl_lookup(obj, :figure)
    if fig === nothing
        return nothing
    end
    fig_module, fig_type = jl_type_parts(fig)
    if (jl_module_matches(fig_module, "Makie") || jl_module_matches(fig_module, "CairoMakie")) && fig_type == "Figure"
        return fig
    end
    nothing
end

function jl_makie_primary_axis(fig)
    content = jl_lookup(fig, :content)
    if !(content isa AbstractVector)
        return nothing
    end
    for item in content
        item_type = string(nameof(typeof(item)))
        if occursin("Axis", item_type)
            return item
        end
    end
    nothing
end

function jl_extract_plot_metadata(obj)
    module_name, type_name = jl_type_parts(obj)

    if jl_module_matches(module_name, "TidierPlots") && (type_name == "GGPlot" || type_name == "GGPlotGrid" || type_name == "Layer")
        labs_obj = jl_lookup(obj, :axis_options)
        if labs_obj !== nothing
            # axis_options usually has an 'opt' field which is the Dict
            inner_opt = jl_lookup(labs_obj, :opt)
            if inner_opt !== nothing; labs_obj = inner_opt; end
        end
        if labs_obj === nothing; labs_obj = jl_lookup(obj, :labs); end
        if labs_obj === nothing; labs_obj = jl_lookup(obj, :labels); end
        
        mapping_obj = jl_lookup(obj, :default_aes)
        if mapping_obj !== nothing
            # default_aes usually has an 'aes' field which is the Dict
            inner_aes = jl_lookup(mapping_obj, :aes)
            if inner_aes !== nothing; mapping_obj = inner_aes; end
        end
        if mapping_obj === nothing; mapping_obj = jl_lookup(obj, :mapping); end
        if mapping_obj === nothing; mapping_obj = jl_lookup(obj, :aes); end
        
        labels = jl_labels_from_container(labs_obj)
        mapping = jl_mapping_to_dict(mapping_obj)
        layers = jl_tidierplots_layers(obj)
        
        # Fallback for mapping from first layer if default is empty
        if isempty(mapping)
             layers_list = jl_lookup(obj, :geoms)
             if layers_list === nothing; layers_list = jl_lookup(obj, :layers); end
             if layers_list isa AbstractVector && !isempty(layers_list)
                 first_layer = first(layers_list)
                 # Layer also has an 'aes' field which might be an Aes object
                 l_mapping_obj = jl_lookup(first_layer, :aes)
                 if l_mapping_obj !== nothing
                     l_inner_aes = jl_lookup(l_mapping_obj, :aes)
                     if l_inner_aes !== nothing; l_mapping_obj = l_inner_aes; end
                 end
                 if l_mapping_obj === nothing; l_mapping_obj = jl_lookup(first_layer, :mapping); end
                 mapping = jl_mapping_to_dict(l_mapping_obj)
             end
        end

        if isempty(labels) && isempty(mapping)
             inner = jl_lookup(obj, :plot)
             if inner !== nothing && inner !== obj
                 return jl_extract_plot_metadata(inner)
             end
        end

        title = get(labels, "title", nothing)
        return Dict(
            "class" => "tidierplots",
            "backend" => "Julia",
            "title" => title,
            "mapping" => mapping,
            "labels" => labels,
            "layers" => layers,
            "_display_keys" => ["class", "backend", "title", "mapping", "labels", "layers"],
        )
    end

    if jl_module_matches(module_name, "Plots") && type_name == "Plot"
        plot_attrs = jl_lookup(obj, :plotattributes)
        subplot = jl_plots_primary_subplot(obj)
        attrs = jl_lookup(subplot, :attr)
        subplot_attrs =
            if attrs === nothing
                jl_lookup(subplot, :plotattributes)
            else
                attrs
            end
        direct_title = jl_first_string(plot_attrs, [:title, "title", :plot_title, "plot_title"])
        title =
            if direct_title === nothing
                jl_first_string(subplot_attrs, [:title, "title", :plot_title, "plot_title"])
            else
                direct_title
            end
        labels = jl_compact_dict([
            "title" => title,
            "x" => jl_first_string(subplot_attrs, [:xlabel, "xlabel", :xguide, "xguide", :guide, "guide"]),
            "y" => jl_first_string(subplot_attrs, [:ylabel, "ylabel", :yguide, "yguide"]),
        ])
        return Dict(
            "class" => "plotsjl",
            "backend" => "Julia",
            "title" => title,
            "labels" => labels,
            "layers" => jl_plots_layers(obj, subplot),
            "_display_keys" => ["class", "backend", "title", "labels", "layers"],
        )
    end

    figure = jl_makie_figure(obj)
    if figure !== nothing
        axis = jl_makie_primary_axis(figure)
        title = jl_first_string(axis, [:title, "title"])
        labels = jl_compact_dict([
            "title" => title,
            "x" => jl_first_string(axis, [:xlabel, "xlabel"]),
            "y" => jl_first_string(axis, [:ylabel, "ylabel"]),
        ])
        content = jl_lookup(figure, :content)
        layers =
            if content isa AbstractVector
                jl_dedup_strings([string(nameof(typeof(item))) for item in content])
            else
                String[]
            end
        return Dict(
            "class" => "makie",
            "backend" => "Julia",
            "title" => title,
            "labels" => labels,
            "layers" => layers,
            "_display_keys" => ["class", "backend", "title", "labels", "layers"],
        )
    end

    nothing
end

function jl_visual_class(obj)
    metadata = jl_extract_plot_metadata(obj)
    metadata === nothing ? string(typeof(obj)) : metadata["class"]
end

function jl_save_viz_metadata(obj, path)
    metadata = jl_extract_plot_metadata(obj)
    if metadata === nothing
        return false
    end
    open(path, "w") do f
        JSON.print(f, metadata)
    end
    true
end

mutable struct TlangNamespace
    dict::Dict{Symbol, Any}
end
Base.getproperty(ns::TlangNamespace, sym::Symbol) = getfield(ns, :dict)[sym]
Base.setproperty!(ns::TlangNamespace, sym::Symbol, val) = (getfield(ns, :dict)[sym] = val)

EOF
      cat << 'EOF' >> node_script.jl

using JSON
function jl_write_json(obj, path)
    open(path, "w") do f
        JSON.print(f, obj)
    end
end
function jl_read_json(path)
    open(path, "r") do f
        JSON.parse(f)
    end
end

EOF








      cat <<'EOF' >> node_script.jl
using Random
EOF

      echo "if isfile(joinpath(\"$T_NODE_demo_data\", \"class\")) && readline(joinpath(\"$T_NODE_demo_data\", \"class\")) == \"VError\"" >> node_script.jl
      echo "    __dep_demo_data = jl_read_json(joinpath(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      echo "    __dep_demo_data = jl_read_json(joinpath(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.jl
      echo "end" >> node_script.jl
      echo "if isfile(joinpath(\"$T_NODE_python_model_state\", \"class\")) && readline(joinpath(\"$T_NODE_python_model_state\", \"class\")) == \"VError\"" >> node_script.jl
      echo "    __dep_python_model_state = jl_read_json(joinpath(\"$T_NODE_python_model_state\", \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      echo "    __dep_python_model_state = jl_read_json(joinpath(\"$T_NODE_python_model_state\", \"artifact\"))" >> node_script.jl
      echo "end" >> node_script.jl
      echo "demo_data = __dep_demo_data" >> node_script.jl
      echo "python_model_state = __dep_python_model_state" >> node_script.jl

      echo "captured_logger = TCaptureLogger()" >> node_script.jl
      echo "try" >> node_script.jl
      echo "    local __tlang_node_thunk = () -> begin" >> node_script.jl
      cat <<'EOF' >> node_script.jl
            Random.seed!(42)
            feature_names = demo_data["feature_names"]
            training_columns = [Float32.(demo_data["training_features"][feature_name]) for feature_name in feature_names]
            training_matrix = reduce(vcat, [permutedims(column) for column in training_columns])
            training_labels = reshape(
                Float32.([label > 0 ? 1.0f0 : 0.0f0 for label in demo_data["training_labels"]]),
                1,
                :
            )
            weights = python_model_state["weights"]
            biases = python_model_state["biases"]
            function to_matrix(v)
                nr = length(v)
                nc = length(v[1])
                mat = zeros(Float32, nr, nc)
                for i in 1:nr, j in 1:nc
                    mat[i, j] = Float32(v[i][j])
                end
                return mat
            end
            W1 = to_matrix(weights[1])${"'"}
            b1 = Float32.(biases[1])
            W2 = to_matrix(weights[2])${"'"}
            b2 = Float32.(biases[2])
            W3 = to_matrix(weights[3])${"'"}
            b3 = Float32.(biases[3])
            lr = 0.05f0
            for epoch in 1:400
                h1 = max.(0.0f0, W1 * training_matrix .+ b1)
                h2 = max.(0.0f0, W2 * h1 .+ b2)
                z3 = W3 * h2 .+ b3
                y_hat = 1.0f0 ./ (1.0f0 .+ exp.(-z3))
                dz3 = (y_hat .- training_labels) ./ size(training_matrix, 2)
                dW3 = dz3 * h2${"'"}
                db3 = vec(sum(dz3, dims=2))
                dh2 = W3${"'"} * dz3 .* (h2 .> 0)
                dW2 = dh2 * h1${"'"}
                db2 = vec(sum(dh2, dims=2))
                dh1 = W2${"'"} * dh2 .* (h1 .> 0)
                dW1 = dh1 * training_matrix${"'"}
                db1 = vec(sum(dh1, dims=2))
                W1 .-= lr .* dW1
                b1 .-= lr .* db1
                W2 .-= lr .* dW2
                b2 .-= lr .* db2
                W3 .-= lr .* dW3
                b3 .-= lr .* db3
            end
            julia_flux_model = Dict(
                "weights" => [Float64.(W1), Float64.(W2), Float64.(W3)],
                "biases"  => [Float64.(b1), Float64.(b2), Float64.(b3)]
            )
EOF
      echo "    end" >> node_script.jl
      echo "    global __node_result = with_logger(captured_logger) do" >> node_script.jl
      echo "        Base.invokelatest(__tlang_node_thunk)" >> node_script.jl
      echo "    end" >> node_script.jl
      echo "catch e" >> node_script.jl
      echo "    jl_write_error(e, joinpath(ENV[\"out\"], \"artifact\"))" >> node_script.jl
      echo "    exit(0)" >> node_script.jl
      echo "end" >> node_script.jl
      echo "if jl_is_error(__node_result)" >> node_script.jl
      echo "    jl_write_error(__node_result, joinpath(ENV[\"out\"], \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      cat <<'EOF' >> node_script.jl
    jl_write_json(__node_result, joinpath(ENV["out"], "artifact"))
EOF
      echo "    open(joinpath(ENV[\"out\"], \"class\"), \"w\") do f; write(f, string(typeof(__node_result))); end" >> node_script.jl
      echo "    jl_write_warnings(captured_logger.warnings, joinpath(ENV[\"out\"], \"warnings\"))" >> node_script.jl
      echo "end" >> node_script.jl
      mkdir -p $out
      julia node_script.jl
    '';
  };
 

  python_predictions = stdenv.mkDerivation {
    name = "python_predictions";
    buildInputs = [ tBin py-env demo_data python_model_state ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    T_NODE_python_model_state = python_model_state;
    T_INPUT_python_model_state = "${python_model_state}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact
      export T_NODE_python_model_state=${python_model_state}
      export T_INPUT_python_model_state=${python_model_state}/artifact

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
import numpy as np
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_demo_data\", \"class\")) and open(os.path.join(\"$T_NODE_demo_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_demo_data = py_read_json(os.path.join(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.py
      echo "if os.path.exists(os.path.join(\"$T_NODE_python_model_state\", \"class\")) and open(os.path.join(\"$T_NODE_python_model_state\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_python_model_state = py_read_json(os.path.join(\"$T_NODE_python_model_state\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_python_model_state = py_read_json(os.path.join(\"$T_NODE_python_model_state\", \"artifact\"))" >> node_script.py
      echo "demo_data = __dep_demo_data" >> node_script.py
      echo "python_model_state = __dep_python_model_state" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np

        test_samples = np.array(demo_data["test_samples"], dtype=np.float32)
        weights = [np.array(layer_weights, dtype=np.float32) for layer_weights in python_model_state["weights"]]
        biases = [np.array(layer_biases, dtype=np.float32) for layer_biases in python_model_state["biases"]]

        activations = test_samples
        for layer_index, (weight_matrix, bias_vector) in enumerate(zip(weights, biases)):
            activations = activations @ weight_matrix + bias_vector
            if layer_index < len(weights) - 1:
                activations = np.maximum(activations, 0.0)

        probabilities = 1.0 / (1.0 + np.exp(-activations[:, 0]))
        predictions = (probabilities >= 0.5).astype(np.float64)

        python_predictions = {
            "predictions": predictions.tolist(),
            "probabilities": probabilities.astype(np.float64).tolist(),
        }
EOF
      echo "    __node_result = python_predictions" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
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
 

  julia_flux_predictions = stdenv.mkDerivation {
    name = "julia_flux_predictions";
    buildInputs = [ tBin juliaPkg demo_data julia_flux_model ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    T_NODE_julia_flux_model = julia_flux_model;
    T_INPUT_julia_flux_model = "${julia_flux_model}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact
      export T_NODE_julia_flux_model=${julia_flux_model}
      export T_INPUT_julia_flux_model=${julia_flux_model}/artifact

      cat << EOF > node_script.jl
using DataFrames, CSV, StatsModels, JSON, Logging, Serialization
EOF
      cat << 'EOF' >> node_script.jl

mutable struct TCaptureLogger <: AbstractLogger
    warnings::Vector{String}
end

TCaptureLogger() = TCaptureLogger(String[])

Logging.min_enabled_level(::TCaptureLogger) = Logging.Warn
Logging.shouldlog(::TCaptureLogger, level, _module, group, id) = level >= Logging.Warn
Logging.catch_exceptions(::TCaptureLogger) = false

function Logging.handle_message(logger::TCaptureLogger, level, message, _module, group, id, file, line; kwargs...)
    if level >= Logging.Warn
        push!(logger.warnings, string(message))
    end
end

using Serialization

function jl_error_message(err)
    try
        sprint(showerror, err)
    catch _
        string(err)
    end
end

function jl_error_traceback(err)
    try
        sprint(io -> showerror(io, err, catch_backtrace()))
    catch _
        jl_error_message(err)
    end
end

function jl_write_error(msg, path)
    err_info =
        if msg isa AbstractDict && get(msg, "type", nothing) == "VError"
            msg
        elseif msg isa AbstractDict && get(msg, :type, nothing) == "VError"
            msg
        else
            traceback_text = jl_error_traceback(msg)
            Dict(
                "type" => "VError",
                "code" => "RuntimeError",
                "message" => jl_error_message(msg),
                "na_count" => 0,
                "context" => Dict(
                    "runtime_traceback" => traceback_text,
                    "node_status" => "errored"
                ),
                "location" => nothing
            )
        end
    open(path, "w") do f
        JSON.print(f, err_info)
    end
    open(joinpath(dirname(path), "class"), "w") do f
        write(f, "VError")
    end
end

function jl_is_error(obj)
    (obj isa AbstractDict && get(obj, "type", nothing) == "VError") ||
    (obj isa AbstractDict && get(obj, :type, nothing) == "VError")
end

function jl_write_warnings(warnings_list, path)
    cleaned = [string(w) for w in warnings_list if !isempty(strip(string(w)))]
    if !isempty(cleaned)
        open(path, "w") do f
            JSON.print(f, cleaned)
        end
    end
end

function jl_serialize(obj, path)
    # T-Lang default Julia serialization uses the standard library Serialization package.
    # Note on Julia-version coupling: native Serialization is process-to-process and not stable
    # across major/minor Julia versions. However, in our sandboxed/pinned Nix architecture,
    # any update to the Julia version in the flake changes the Nix store path, which naturally
    # invalidates and rebuilds the cache anyway.
    try
        Serialization.serialize(path, obj)
        return path
    catch err
        err_msg = jl_error_message(err)
        error(
            "T-Lang Julia serialization error: failed to serialize object of type $(typeof(obj)) " *
            "using native Serialization at $(path). Underlying error: $(err_msg)"
        )
    end
end

EOF
      cat << 'EOF' >> node_script.jl

import JSON

function jl_non_empty_string(value)
    try
        !isempty(strip(string(value)))
    catch
        false
    end
end

function jl_string_or_nothing(value)
    value === nothing && return nothing
    raw =
        try
            if applicable(getindex, value)
                value[]
            else
                value
            end
        catch
            value
        end
    try
        text = strip(string(raw))
        isempty(text) ? nothing : text
    catch
        nothing
    end
end

function jl_compact_dict(entries)
    out = Dict{String, Any}()
    for (key, value) in entries
        if value === nothing
            continue
        elseif value isa AbstractString && isempty(strip(value))
            continue
        elseif value isa AbstractVector && isempty(value)
            continue
        elseif value isa AbstractDict && isempty(value)
            continue
        end
        out[string(key)] = value
    end
    out
end

function jl_lookup(container, key)
    container === nothing && return nothing
    candidates =
        if key isa Symbol
            Any[key, String(key)]
        elseif key isa AbstractString
            Any[key, Symbol(key)]
        else
            Any[key]
        end
    for candidate in candidates
        if container isa AbstractDict
            if haskey(container, candidate)
                return container[candidate]
            end
        elseif container isa NamedTuple
            if candidate isa Symbol && candidate in keys(container)
                return getproperty(container, candidate)
            end
        else
            # Try getproperty first
            try
                if candidate isa Symbol && hasproperty(container, candidate)
                    return getproperty(container, candidate)
                end
            catch
            end
            # Fallback to getfield for structs
            try
                if candidate isa Symbol && candidate in fieldnames(typeof(container))
                    return getfield(container, candidate)
                end
            catch
            end
        end
    end
    nothing
end

function jl_type_parts(obj)
    T = typeof(obj)
    (string(parentmodule(T)), string(nameof(T)))
end

function jl_module_matches(module_name, expected)
    module_name == expected || endswith(module_name, "." * expected)
end

function jl_first_string(container, keys)
    for key in keys
        value = jl_string_or_nothing(jl_lookup(container, key))
        if value !== nothing
            return value
        end
    end
    nothing
end

function jl_mapping_to_dict(mapping)
    mapping === nothing && return Dict{String, Any}()
    out = Dict{String, Any}()
    if mapping isa AbstractDict
        for (key, value) in mapping
            cleaned = jl_string_or_nothing(value)
            if cleaned !== nothing
                out[string(key)] = cleaned
            end
        end
        return out
    end
    keys_list =
        try
            collect(propertynames(mapping))
        catch
            Any[]
        end
    for key in keys_list
        cleaned = jl_string_or_nothing(jl_lookup(mapping, key))
        if cleaned !== nothing
            out[string(key)] = cleaned
        end
    end
    out
end

function jl_labels_from_container(container)
    labels = Dict{String, Any}()
    for key in ["title", "subtitle", "caption", "x", "y", "xlabel", "ylabel", "color", "colour", "fill"]
        value = jl_string_or_nothing(jl_lookup(container, key))
        if value !== nothing
            normalized =
                key == "xlabel" ? "x" :
                key == "ylabel" ? "y" :
                key == "colour" ? "color" :
                key
            labels[normalized] = value
        end
    end
    labels
end

function jl_dedup_strings(items)
    seen = Set{String}()
    out = String[]
    for item in items
        value = jl_string_or_nothing(item)
        if value !== nothing && !(value in seen)
            push!(seen, value)
            push!(out, value)
        end
    end
    out
end

function jl_tidierplots_layers(obj)
    layers = jl_lookup(obj, :geoms)
    if layers === nothing; layers = jl_lookup(obj, :layers); end
    if !(layers isa AbstractVector)
        plots = jl_lookup(obj, :plots)
        if plots isa AbstractVector
            return ["GGPlotGrid (" * string(length(plots)) * " plots)"]
        end
        inner = jl_lookup(obj, :plot)
        if inner !== nothing && inner !== obj
            return jl_tidierplots_layers(inner)
        end
        return String[]
    end
    jl_dedup_strings([
        begin
            # Try various fields for the geom name
            geom = jl_lookup(layer, :geom)
            if geom === nothing; geom = jl_lookup(layer, :type); end
            if geom === nothing; geom = jl_lookup(layer, :geom_type); end
            if geom === nothing; geom = jl_lookup(layer, :layer_type); end
            
            name =
                if geom !== nothing
                    string(nameof(typeof(geom)))
                else
                    # Fallback to the layer object's own type
                    string(nameof(typeof(layer)))
                end
            
            # Clean up common suffixes
            name = replace(name, "Geom" => "")
            name = replace(name, "Layer" => "")
            name
        end
        for layer in layers
    ])
end

function jl_plots_primary_subplot(obj)
    subplots = jl_lookup(obj, :subplots)
    if subplots isa AbstractVector && !isempty(subplots)
        return first(subplots)
    end
    nothing
end

function jl_plots_layers(obj, subplot)
    series_sources = Any[]
    for container in (obj, subplot)
        series = jl_lookup(container, :series_list)
        if series isa AbstractVector
            append!(series_sources, series)
        end
    end
    if isempty(series_sources)
        return String[]
    end
    jl_dedup_strings([
        begin
            attrs = jl_lookup(series, :plotattributes)
            seriestype = jl_string_or_nothing(jl_lookup(attrs, :seriestype))
            if seriestype === nothing
                seriestype = jl_string_or_nothing(jl_lookup(series, :seriestype))
            end
            seriestype === nothing ? string(nameof(typeof(series))) : seriestype
        end
        for series in series_sources
    ])
end

function jl_makie_figure(obj)
    module_name, type_name = jl_type_parts(obj)
    if jl_module_matches(module_name, "Makie") || jl_module_matches(module_name, "CairoMakie")
        if type_name == "Figure"
            return obj
        elseif startswith(type_name, "FigureAxisPlot")
            fig = jl_lookup(obj, :figure)
            if fig !== nothing
                return fig
            end
        end
    end
    fig = jl_lookup(obj, :figure)
    if fig === nothing
        return nothing
    end
    fig_module, fig_type = jl_type_parts(fig)
    if (jl_module_matches(fig_module, "Makie") || jl_module_matches(fig_module, "CairoMakie")) && fig_type == "Figure"
        return fig
    end
    nothing
end

function jl_makie_primary_axis(fig)
    content = jl_lookup(fig, :content)
    if !(content isa AbstractVector)
        return nothing
    end
    for item in content
        item_type = string(nameof(typeof(item)))
        if occursin("Axis", item_type)
            return item
        end
    end
    nothing
end

function jl_extract_plot_metadata(obj)
    module_name, type_name = jl_type_parts(obj)

    if jl_module_matches(module_name, "TidierPlots") && (type_name == "GGPlot" || type_name == "GGPlotGrid" || type_name == "Layer")
        labs_obj = jl_lookup(obj, :axis_options)
        if labs_obj !== nothing
            # axis_options usually has an 'opt' field which is the Dict
            inner_opt = jl_lookup(labs_obj, :opt)
            if inner_opt !== nothing; labs_obj = inner_opt; end
        end
        if labs_obj === nothing; labs_obj = jl_lookup(obj, :labs); end
        if labs_obj === nothing; labs_obj = jl_lookup(obj, :labels); end
        
        mapping_obj = jl_lookup(obj, :default_aes)
        if mapping_obj !== nothing
            # default_aes usually has an 'aes' field which is the Dict
            inner_aes = jl_lookup(mapping_obj, :aes)
            if inner_aes !== nothing; mapping_obj = inner_aes; end
        end
        if mapping_obj === nothing; mapping_obj = jl_lookup(obj, :mapping); end
        if mapping_obj === nothing; mapping_obj = jl_lookup(obj, :aes); end
        
        labels = jl_labels_from_container(labs_obj)
        mapping = jl_mapping_to_dict(mapping_obj)
        layers = jl_tidierplots_layers(obj)
        
        # Fallback for mapping from first layer if default is empty
        if isempty(mapping)
             layers_list = jl_lookup(obj, :geoms)
             if layers_list === nothing; layers_list = jl_lookup(obj, :layers); end
             if layers_list isa AbstractVector && !isempty(layers_list)
                 first_layer = first(layers_list)
                 # Layer also has an 'aes' field which might be an Aes object
                 l_mapping_obj = jl_lookup(first_layer, :aes)
                 if l_mapping_obj !== nothing
                     l_inner_aes = jl_lookup(l_mapping_obj, :aes)
                     if l_inner_aes !== nothing; l_mapping_obj = l_inner_aes; end
                 end
                 if l_mapping_obj === nothing; l_mapping_obj = jl_lookup(first_layer, :mapping); end
                 mapping = jl_mapping_to_dict(l_mapping_obj)
             end
        end

        if isempty(labels) && isempty(mapping)
             inner = jl_lookup(obj, :plot)
             if inner !== nothing && inner !== obj
                 return jl_extract_plot_metadata(inner)
             end
        end

        title = get(labels, "title", nothing)
        return Dict(
            "class" => "tidierplots",
            "backend" => "Julia",
            "title" => title,
            "mapping" => mapping,
            "labels" => labels,
            "layers" => layers,
            "_display_keys" => ["class", "backend", "title", "mapping", "labels", "layers"],
        )
    end

    if jl_module_matches(module_name, "Plots") && type_name == "Plot"
        plot_attrs = jl_lookup(obj, :plotattributes)
        subplot = jl_plots_primary_subplot(obj)
        attrs = jl_lookup(subplot, :attr)
        subplot_attrs =
            if attrs === nothing
                jl_lookup(subplot, :plotattributes)
            else
                attrs
            end
        direct_title = jl_first_string(plot_attrs, [:title, "title", :plot_title, "plot_title"])
        title =
            if direct_title === nothing
                jl_first_string(subplot_attrs, [:title, "title", :plot_title, "plot_title"])
            else
                direct_title
            end
        labels = jl_compact_dict([
            "title" => title,
            "x" => jl_first_string(subplot_attrs, [:xlabel, "xlabel", :xguide, "xguide", :guide, "guide"]),
            "y" => jl_first_string(subplot_attrs, [:ylabel, "ylabel", :yguide, "yguide"]),
        ])
        return Dict(
            "class" => "plotsjl",
            "backend" => "Julia",
            "title" => title,
            "labels" => labels,
            "layers" => jl_plots_layers(obj, subplot),
            "_display_keys" => ["class", "backend", "title", "labels", "layers"],
        )
    end

    figure = jl_makie_figure(obj)
    if figure !== nothing
        axis = jl_makie_primary_axis(figure)
        title = jl_first_string(axis, [:title, "title"])
        labels = jl_compact_dict([
            "title" => title,
            "x" => jl_first_string(axis, [:xlabel, "xlabel"]),
            "y" => jl_first_string(axis, [:ylabel, "ylabel"]),
        ])
        content = jl_lookup(figure, :content)
        layers =
            if content isa AbstractVector
                jl_dedup_strings([string(nameof(typeof(item))) for item in content])
            else
                String[]
            end
        return Dict(
            "class" => "makie",
            "backend" => "Julia",
            "title" => title,
            "labels" => labels,
            "layers" => layers,
            "_display_keys" => ["class", "backend", "title", "labels", "layers"],
        )
    end

    nothing
end

function jl_visual_class(obj)
    metadata = jl_extract_plot_metadata(obj)
    metadata === nothing ? string(typeof(obj)) : metadata["class"]
end

function jl_save_viz_metadata(obj, path)
    metadata = jl_extract_plot_metadata(obj)
    if metadata === nothing
        return false
    end
    open(path, "w") do f
        JSON.print(f, metadata)
    end
    true
end

mutable struct TlangNamespace
    dict::Dict{Symbol, Any}
end
Base.getproperty(ns::TlangNamespace, sym::Symbol) = getfield(ns, :dict)[sym]
Base.setproperty!(ns::TlangNamespace, sym::Symbol, val) = (getfield(ns, :dict)[sym] = val)

EOF
      cat << 'EOF' >> node_script.jl

using JSON
function jl_write_json(obj, path)
    open(path, "w") do f
        JSON.print(f, obj)
    end
end
function jl_read_json(path)
    open(path, "r") do f
        JSON.parse(f)
    end
end

EOF









      echo "if isfile(joinpath(\"$T_NODE_demo_data\", \"class\")) && readline(joinpath(\"$T_NODE_demo_data\", \"class\")) == \"VError\"" >> node_script.jl
      echo "    __dep_demo_data = jl_read_json(joinpath(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      echo "    __dep_demo_data = jl_read_json(joinpath(\"$T_NODE_demo_data\", \"artifact\"))" >> node_script.jl
      echo "end" >> node_script.jl
      echo "if isfile(joinpath(\"$T_NODE_julia_flux_model\", \"class\")) && readline(joinpath(\"$T_NODE_julia_flux_model\", \"class\")) == \"VError\"" >> node_script.jl
      echo "    __dep_julia_flux_model = jl_read_json(joinpath(\"$T_NODE_julia_flux_model\", \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      echo "    __dep_julia_flux_model = jl_read_json(joinpath(\"$T_NODE_julia_flux_model\", \"artifact\"))" >> node_script.jl
      echo "end" >> node_script.jl
      echo "demo_data = __dep_demo_data" >> node_script.jl
      echo "julia_flux_model = __dep_julia_flux_model" >> node_script.jl

      echo "captured_logger = TCaptureLogger()" >> node_script.jl
      echo "try" >> node_script.jl
      echo "    local __tlang_node_thunk = () -> begin" >> node_script.jl
      cat <<'EOF' >> node_script.jl
            test_rows = [Float32.(row) for row in demo_data["test_samples"]]
                        test_samples = reduce(hcat, test_rows)
                        function to_matrix(v)
                            nr = length(v)
                            nc = length(v[1])
                            mat = zeros(Float32, nr, nc)
                            for i in 1:nr, j in 1:nc
                                mat[i, j] = Float32(v[i][j])
                            end
                            return mat
                        end
                        weights = [permutedims(to_matrix(w)) for w in julia_flux_model["weights"]]
                        biases = [Float32.(bias_values) for bias_values in julia_flux_model["biases"]]
                        h1 = max.(0.0f0, weights[1] * test_samples .+ biases[1])
                        h2 = max.(0.0f0, weights[2] * h1 .+ biases[2])
                        z3 = weights[3] * h2 .+ biases[3]
                        julia_probabilities = vec(Float64.(1.0f0 ./ (1.0f0 .+ exp.(-z3))))
                        julia_predictions = Float64.(julia_probabilities .>= 0.5)
                        Dict(
                            "predictions" => julia_predictions,
                            "probabilities" => julia_probabilities
                        )
EOF
      echo "    end" >> node_script.jl
      echo "    global __node_result = with_logger(captured_logger) do" >> node_script.jl
      echo "        Base.invokelatest(__tlang_node_thunk)" >> node_script.jl
      echo "    end" >> node_script.jl
      echo "catch e" >> node_script.jl
      echo "    jl_write_error(e, joinpath(ENV[\"out\"], \"artifact\"))" >> node_script.jl
      echo "    exit(0)" >> node_script.jl
      echo "end" >> node_script.jl
      echo "if jl_is_error(__node_result)" >> node_script.jl
      echo "    jl_write_error(__node_result, joinpath(ENV[\"out\"], \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      cat <<'EOF' >> node_script.jl
    jl_write_json(__node_result, joinpath(ENV["out"], "artifact"))
EOF
      echo "    open(joinpath(ENV[\"out\"], \"class\"), \"w\") do f; write(f, string(typeof(__node_result))); end" >> node_script.jl
      echo "    jl_write_warnings(captured_logger.warnings, joinpath(ENV[\"out\"], \"warnings\"))" >> node_script.jl
      echo "end" >> node_script.jl
      mkdir -p $out
      julia node_script.jl
    '';
  };
 

  t_predictions = stdenv.mkDerivation {
    name = "t_predictions";
    buildInputs = [ tBin demo_data python_model ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_demo_data = demo_data;
    T_INPUT_demo_data = "${demo_data}/artifact";
    T_NODE_python_model = python_model;
    T_INPUT_python_model = "${python_model}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_demo_data=${demo_data}
      export T_INPUT_demo_data=${demo_data}/artifact
      export T_NODE_python_model=${python_model}
      export T_INPUT_python_model=${python_model}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_demo_data/class\") && (read_file(\"$T_NODE_demo_data/class\") == \"VError\" || read_file(\"$T_NODE_demo_data/class\") == \"VError\\n\" || read_file(\"$T_NODE_demo_data/class\") == \"Error\" || read_file(\"$T_NODE_demo_data/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_demo_data = deserialize(\"$T_NODE_demo_data/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_demo_data = t_read_json(\"$T_NODE_demo_data/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_python_model/class\") && (read_file(\"$T_NODE_python_model/class\") == \"VError\" || read_file(\"$T_NODE_python_model/class\") == \"VError\\n\" || read_file(\"$T_NODE_python_model/class\") == \"Error\" || read_file(\"$T_NODE_python_model/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_python_model = deserialize(\"$T_NODE_python_model/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_python_model = t_read_onnx(\"$T_NODE_python_model/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
python_model = __dep_python_model
EOF
      cat <<'EOF' >> node_script.t
demo_data = __dep_demo_data
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
test_samples = to_dataframe([
                f0: demo_data.test_features.f0,
                f1: demo_data.test_features.f1,
                f2: demo_data.test_features.f2,
                f3: demo_data.test_features.f3,
                f4: demo_data.test_features.f4,
                f5: demo_data.test_features.f5,
                f6: demo_data.test_features.f6,
                f7: demo_data.test_features.f7,
                f8: demo_data.test_features.f8,
                f9: demo_data.test_features.f9
            ])
            predict(test_samples, python_model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validate_parity = stdenv.mkDerivation {
    name = "validate_parity";
    buildInputs = [ tBin julia_flux_predictions python_predictions t_predictions ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_julia_flux_predictions = julia_flux_predictions;
    T_INPUT_julia_flux_predictions = "${julia_flux_predictions}/artifact";
    T_NODE_python_predictions = python_predictions;
    T_INPUT_python_predictions = "${python_predictions}/artifact";
    T_NODE_t_predictions = t_predictions;
    T_INPUT_t_predictions = "${t_predictions}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_julia_flux_predictions=${julia_flux_predictions}
      export T_INPUT_julia_flux_predictions=${julia_flux_predictions}/artifact
      export T_NODE_python_predictions=${python_predictions}
      export T_INPUT_python_predictions=${python_predictions}/artifact
      export T_NODE_t_predictions=${t_predictions}
      export T_INPUT_t_predictions=${t_predictions}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_julia_flux_predictions/class\") && (read_file(\"$T_NODE_julia_flux_predictions/class\") == \"VError\" || read_file(\"$T_NODE_julia_flux_predictions/class\") == \"VError\\n\" || read_file(\"$T_NODE_julia_flux_predictions/class\") == \"Error\" || read_file(\"$T_NODE_julia_flux_predictions/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_julia_flux_predictions = deserialize(\"$T_NODE_julia_flux_predictions/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_julia_flux_predictions = t_read_json(\"$T_NODE_julia_flux_predictions/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_python_predictions/class\") && (read_file(\"$T_NODE_python_predictions/class\") == \"VError\" || read_file(\"$T_NODE_python_predictions/class\") == \"VError\\n\" || read_file(\"$T_NODE_python_predictions/class\") == \"Error\" || read_file(\"$T_NODE_python_predictions/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_python_predictions = deserialize(\"$T_NODE_python_predictions/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_python_predictions = t_read_json(\"$T_NODE_python_predictions/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_t_predictions/class\") && (read_file(\"$T_NODE_t_predictions/class\") == \"VError\" || read_file(\"$T_NODE_t_predictions/class\") == \"VError\\n\" || read_file(\"$T_NODE_t_predictions/class\") == \"Error\" || read_file(\"$T_NODE_t_predictions/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_t_predictions = deserialize(\"$T_NODE_t_predictions/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_t_predictions = t_read_json(\"$T_NODE_t_predictions/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
t_predictions = __dep_t_predictions
EOF
      cat <<'EOF' >> node_script.t
python_predictions = __dep_python_predictions
EOF
      cat <<'EOF' >> node_script.t
julia_flux_predictions = __dep_julia_flux_predictions
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
t_preds = if (is_error(t_predictions)) { [] } else { t_predictions }
            py_preds = if (is_error(python_predictions)) { [] } else { python_predictions.predictions }
            jl_preds = if (is_error(julia_flux_predictions)) { [] } else { julia_flux_predictions.predictions }
            py_probs = if (is_error(python_predictions)) { [] } else { python_predictions.probabilities }
            jl_probs = if (is_error(julia_flux_predictions)) { [] } else { julia_flux_predictions.probabilities }
            assert(length(t_preds) == length(py_preds) && sum(ifelse(t_preds .== py_preds, 1.0, 0.0)) == length(t_preds), "T-Lang ONNX Neural Network scoring does not match Python predictions!")
            assert(length(jl_preds) == length(py_preds), "Julia Flux predictions length does not match Python predictions length!")
            assert(length(jl_probs) == length(py_probs), "Julia Flux probabilities length does not match Python probabilities length!")
            label_agreement = sum(ifelse(jl_preds .== py_preds, 1.0, 0.0))
            probability_diff = if (length(jl_probs) > 0 && length(py_probs) > 0) { diffs = jl_probs .- py_probs; sum(ifelse(diffs .>= 0, diffs, 0 .- diffs)) } else { 0 }
            python_vs_t_label_parity_passed = (length(t_preds) > 0 && length(t_preds) == length(py_preds) && sum(ifelse(t_preds .== py_preds, 1.0, 0.0)) == length(t_preds))
            [
                python_vs_t_label_parity_passed: python_vs_t_label_parity_passed,
                evaluated_test_samples: length(py_preds),
                python_vs_julia_matching_labels: label_agreement,
                python_vs_julia_total_probability_abs_diff: probability_diff,
                julia_model_trained_independently: true
            ]
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin demo_data python_model python_model_state julia_flux_model python_predictions julia_flux_predictions t_predictions validate_parity projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${demo_data} $out/demo_data
      cp -r ${python_model} $out/python_model
      cp -r ${python_model_state} $out/python_model_state
      cp -r ${julia_flux_model} $out/julia_flux_model
      cp -r ${python_predictions} $out/python_predictions
      cp -r ${julia_flux_predictions} $out/julia_flux_predictions
      cp -r ${t_predictions} $out/t_predictions
      cp -r ${validate_parity} $out/validate_parity
    '';
  };
}

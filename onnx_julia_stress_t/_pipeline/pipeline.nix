
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
  
    rSerializerPackages = [ "jsonlite" ];
    pySerializerPackages = [ "onnxruntime" "pandas" "skl2onnx" ];
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

  synthetic_data = stdenv.mkDerivation {
    name = "synthetic_data";
    buildInputs = [ tBin r-env ] ++ globalBuildInputs;
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

      cat << EOF > node_script.R

EOF
      cat << 'EOF' >> node_script.R

r_write_error <- function(msg, path) {
  if (is.list(msg) && !is.null(msg$type) && msg$type == "VError") {
    err_info <- msg
  } else {
    err_info <- list(
      type = "VError",
      code = "RuntimeError",
      message = as.character(msg),
      na_count = 0,
      context = list(
        runtime_traceback = as.character(msg),
        node_status = "errored"
      ),
      location = NULL
    )
  }
  jsonlite::write_json(err_info, path, auto_unbox = TRUE)
  writeLines("VError", file.path(dirname(path), "class"))
}

r_is_error <- function(obj) {
  is.list(obj) && !is.null(obj$type) && obj$type == "VError"
}

r_write_warnings <- function(warns, path) {
  if (length(warns) > 0) {
    jsonlite::write_json(as.character(warns), path)
  }
}

EOF
      cat << 'EOF' >> node_script.R

r_non_empty_string <- function(value) {
  is.character(value) && length(value) > 0 && !is.na(value[[1]]) && nzchar(value[[1]])
}

r_compact_named_list <- function(entries) {
  entries <- Filter(Negate(is.null), entries)
  if (length(entries) == 0) {
    list()
  } else {
    do.call(c, entries)
  }
}

r_mapping_to_list <- function(mapping) {
  if (is.null(mapping) || length(mapping) == 0) {
    return(list())
  }
  r_compact_named_list(lapply(names(mapping), function(name) {
    value <- mapping[[name]]
    label <- tryCatch(rlang::as_label(value), error = function(e) NULL)
    if (is.null(label) || !nzchar(label)) NULL else setNames(list(label), name)
  }))
}

r_labels_to_list <- function(plot) {
  label_keys <- c("title", "subtitle", "caption", "x", "y", "colour", "color", "fill")
  r_compact_named_list(lapply(label_keys, function(key) {
    value <- plot$labels[[key]]
    if (r_non_empty_string(value)) setNames(list(as.character(value[[1]])), key) else NULL
  }))
}

r_layers_to_list <- function(plot) {
  if (is.null(plot$layers) || length(plot$layers) == 0) {
    list()
  } else {
    as.list(vapply(plot$layers, function(layer) {
      geom_class <- class(layer$geom)[1]
      sub("^Geom", "", geom_class)
    }, character(1)))
  }
}

r_extract_plot_metadata <- function(object) {
  if (!inherits(object, "ggplot")) {
    return(NULL)
  }
  labels <- r_labels_to_list(object)
  title <- labels$title
  if (!r_non_empty_string(title)) {
    title <- NULL
  } else {
    title <- as.character(title[[1]])
  }
  mapping <- r_mapping_to_list(object$mapping)
  metadata <- list(
    class = "ggplot",
    backend = "R",
    title = title,
    mapping = mapping,
    labels = labels,
    layers = r_layers_to_list(object),
    `_display_keys` = c("class", "backend", "title", "mapping", "labels", "layers")
  )
  metadata
}

r_visual_class <- function(object) {
  metadata <- r_extract_plot_metadata(object)
  if (!is.null(metadata)) {
    metadata$class
  } else {
    as.character(class(object)[1])
  }
}

r_save_viz_metadata <- function(object, path) {
  metadata <- r_extract_plot_metadata(object)
  if (is.null(metadata)) {
    return(FALSE)
  }
  jsonlite::write_json(metadata, path, auto_unbox = TRUE, null = "null")
  TRUE
}

EOF

      cat << 'EOF' >> node_script.R

r_write_csv <- function(object, path) {
  if (inherits(object, "data.frame")) {
    write.csv(object, path, row.names = FALSE)
  } else {
    write.csv(as.data.frame(object), path, row.names = FALSE)
  }
}
r_read_csv <- function(path) {
  read.csv(path, stringsAsFactors = FALSE)
}

EOF










      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
set.seed(42)
        n <- 100
        x1 <- runif(n, -2, 2)
        x2 <- runif(n, -2, 2)
        y <- 3 * x1 - 2 * x2 + sin(x1 * x2) + rnorm(n, sd = 0.05)
        data.frame(x1 = x1, x2 = x2, y = y)
EOF
      echo "    }, error = function(e) {" >> node_script.R
      echo "      r_write_error(e, \"$out/artifact\")" >> node_script.R
      echo "      quit(save = 'no', status = 0)" >> node_script.R
      echo "    })" >> node_script.R
      echo "  })" >> node_script.R
      echo "}, warning = function(w) {" >> node_script.R
      echo "  captured_warns <<- append(captured_warns, conditionMessage(w))" >> node_script.R
      echo "  invokeRestart('muffleWarning')" >> node_script.R
      echo "})" >> node_script.R
       echo "if (r_is_error(node_result)) {" >> node_script.R
       echo "  r_write_error(node_result, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_csv(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  py_model_params = stdenv.mkDerivation {
    name = "py_model_params";
    buildInputs = [ tBin py-env synthetic_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_synthetic_data = synthetic_data;
    T_INPUT_synthetic_data = "${synthetic_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_synthetic_data=${synthetic_data}
      export T_INPUT_synthetic_data=${synthetic_data}/artifact

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

import pandas as _pd
def py_write_csv(obj, path):
    if hasattr(obj, 'to_pandas'):
        obj = obj.to_pandas()
    if hasattr(obj, 'to_csv'):
        obj.to_csv(path, index=False)
    else:
        _pd.DataFrame(obj).to_csv(path, index=False)
def py_read_csv(path):
    return _pd.read_csv(path)

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
from sklearn.neural_network import MLPRegressor
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_synthetic_data\", \"class\")) and open(os.path.join(\"$T_NODE_synthetic_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_synthetic_data = py_read_json(os.path.join(\"$T_NODE_synthetic_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_synthetic_data = py_read_csv(os.path.join(\"$T_NODE_synthetic_data\", \"artifact\"))" >> node_script.py
      echo "synthetic_data = __dep_synthetic_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np
        from sklearn.neural_network import MLPRegressor

        # Prepare data directly from the injected DataFrame
        X = synthetic_data[["x1", "x2"]].values.astype(np.float32)
        y = synthetic_data["y"].values.astype(np.float32)

        # Train a neural network using standard mathematical operators
        model = MLPRegressor(hidden_layer_sizes=(5, 3), max_iter=500, random_state=42)
        model.fit(X, y)

        # Export weights and biases to verify mathematically
        py_model_params = {
            "coefs": [c.tolist() for c in model.coefs_],
            "intercepts": [i.tolist() for i in model.intercepts_]
        }
EOF
      echo "    __node_result = py_model_params" >> node_script.py
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
 

  py_model = stdenv.mkDerivation {
    name = "py_model";
    buildInputs = [ tBin py-env synthetic_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_synthetic_data = synthetic_data;
    T_INPUT_synthetic_data = "${synthetic_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_synthetic_data=${synthetic_data}
      export T_INPUT_synthetic_data=${synthetic_data}/artifact

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

import pandas as _pd
def py_write_csv(obj, path):
    if hasattr(obj, 'to_pandas'):
        obj = obj.to_pandas()
    if hasattr(obj, 'to_csv'):
        obj.to_csv(path, index=False)
    else:
        _pd.DataFrame(obj).to_csv(path, index=False)
def py_read_csv(path):
    return _pd.read_csv(path)

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
from sklearn.neural_network import MLPRegressor
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_synthetic_data\", \"class\")) and open(os.path.join(\"$T_NODE_synthetic_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_synthetic_data = py_read_json(os.path.join(\"$T_NODE_synthetic_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_synthetic_data = py_read_csv(os.path.join(\"$T_NODE_synthetic_data\", \"artifact\"))" >> node_script.py
      echo "synthetic_data = __dep_synthetic_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np
        from sklearn.neural_network import MLPRegressor

        # Prepare data directly from the injected DataFrame
        X = synthetic_data[["x1", "x2"]].values.astype(np.float32)
        y = synthetic_data["y"].values.astype(np.float32)

        # Re-train exact same model to export to ONNX
        model = MLPRegressor(hidden_layer_sizes=(5, 3), max_iter=500, random_state=42)
        model.fit(X, y)

        # Simply assign the model to py_model. T-Lang${"'"}s ^onnx serializer does the conversion automatically!
        py_model = model
EOF
      echo "    __node_result = py_model" >> node_script.py
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
 

  julia_model = stdenv.mkDerivation {
    name = "julia_model";
    buildInputs = [ tBin juliaPkg py_model ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_py_model = py_model;
    T_INPUT_py_model = "${py_model}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_py_model=${py_model}
      export T_INPUT_py_model=${py_model}/artifact

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




      cat << 'EOF' >> node_script.jl

import ONNXRunTime as ORT
using ONNX

function jl_write_onnx(model, path)
    try
        ONNX.save(path, model)
    catch e
        if e isa MethodError
            error("T-Lang Julia ONNX export error: $(typeof(model)) is not compatible with ONNX.jl. Only ONNX.jl-supported graph/tape objects can be written directly in Julia.")
        else
            error("ONNX serialization failed in Julia: $(sprint(showerror, e))")
        end
    end
end

function jl_read_onnx(path)
    try
        return ORT.load_inference(path)
    catch e
        error("ONNX deserialization failed in Julia: $(sprint(showerror, e))")
    end
end

EOF



      cat <<'EOF' >> node_script.jl
using ONNX
using Umlaut
import ONNX: GraphProto, NodeProto, OpConfig, load_node!, save_node!
EOF

      echo "if isfile(joinpath(\"$T_NODE_py_model\", \"class\")) && readline(joinpath(\"$T_NODE_py_model\", \"class\")) == \"VError\"" >> node_script.jl
      echo "    __dep_py_model = jl_read_json(joinpath(\"$T_NODE_py_model\", \"artifact\"))" >> node_script.jl
      echo "else" >> node_script.jl
      echo "    __dep_py_model = identity(joinpath(\"$T_NODE_py_model\", \"artifact\"))" >> node_script.jl
      echo "end" >> node_script.jl
      echo "py_model = __dep_py_model" >> node_script.jl

      echo "captured_logger = TCaptureLogger()" >> node_script.jl
      echo "try" >> node_script.jl
      echo "    local __tlang_node_thunk = () -> begin" >> node_script.jl
      cat <<'EOF' >> node_script.jl
            @eval function onnx_reshape(x, s)
                julia_shape = map(val -> val < 0 ? Colon() : Int(val), s)
                reshape(x, julia_shape...)
            end
            @eval ONNX function load_node!(tape::Umlaut.Tape, ::OpConfig{:ONNX, :Cast}, args::Vector{Umlaut.Variable}, attrs::Dict{Symbol, Any})
                return ONNX.push_call!(tape, identity, args[1])
            end
            @eval ONNX function load_node!(tape::Umlaut.Tape, ::OpConfig{:ONNX, :Reshape}, args::Vector{Umlaut.Variable}, attrs::Dict{Symbol, Any})
                return ONNX.push_call!(tape, Main.onnx_reshape, args[1], args[2])
            end
            @eval ONNX function save_node!(g::GraphProto, ::OpConfig{:ONNX, typeof(identity)}, op::Umlaut.Call)
                nd = NodeProto("Identity", op)
                push!(g.node, nd)
            end
            @eval ONNX function save_node!(g::GraphProto, ::OpConfig{:ONNX, typeof(Main.onnx_reshape)}, op::Umlaut.Call)
                nd = NodeProto("Reshape", op)
                push!(g.node, nd)
            end
            dummy_in = fill(Float32(1.0), 2, 1)
            tape = Base.invokelatest(ONNX.load, py_model, dummy_in)
            tape
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
    jl_write_onnx(__node_result, joinpath(ENV["out"], "artifact"))
EOF
      echo "    open(joinpath(ENV[\"out\"], \"class\"), \"w\") do f; write(f, string(typeof(__node_result))); end" >> node_script.jl
      echo "    jl_write_warnings(captured_logger.warnings, joinpath(ENV[\"out\"], \"warnings\"))" >> node_script.jl
      echo "end" >> node_script.jl
      mkdir -p $out
      julia node_script.jl
    '';
  };
 

  t_predict = stdenv.mkDerivation {
    name = "t_predict";
    buildInputs = [ tBin julia_model ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_julia_model = julia_model;
    T_INPUT_julia_model = "${julia_model}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_julia_model=${julia_model}
      export T_INPUT_julia_model=${julia_model}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_julia_model/class\") && (read_file(\"$T_NODE_julia_model/class\") == \"VError\" || read_file(\"$T_NODE_julia_model/class\") == \"VError\\n\" || read_file(\"$T_NODE_julia_model/class\") == \"Error\" || read_file(\"$T_NODE_julia_model/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_julia_model = deserialize(\"$T_NODE_julia_model/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_julia_model = t_read_onnx(\"$T_NODE_julia_model/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
julia_model = __dep_julia_model
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
-- A single test sample with two features (x1, x2)
        test_df = to_dataframe([
            x1: [1.25],
            x2: [-0.75]
        ])
        -- Run native prediction in T-Lang
        res = predict(test_df, julia_model)
        to_dataframe([ prediction: res ])
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_csv(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  py_predict = stdenv.mkDerivation {
    name = "py_predict";
    buildInputs = [ tBin py-env py_model_params ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_py_model_params = py_model_params;
    T_INPUT_py_model_params = "${py_model_params}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_py_model_params=${py_model_params}
      export T_INPUT_py_model_params=${py_model_params}/artifact

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

import pandas as _pd
def py_write_csv(obj, path):
    if hasattr(obj, 'to_pandas'):
        obj = obj.to_pandas()
    if hasattr(obj, 'to_csv'):
        obj.to_csv(path, index=False)
    else:
        _pd.DataFrame(obj).to_csv(path, index=False)
def py_read_csv(path):
    return _pd.read_csv(path)

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
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_py_model_params\", \"class\")) and open(os.path.join(\"$T_NODE_py_model_params\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_py_model_params = py_read_json(os.path.join(\"$T_NODE_py_model_params\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_py_model_params = py_read_json(os.path.join(\"$T_NODE_py_model_params\", \"artifact\"))" >> node_script.py
      echo "py_model_params = __dep_py_model_params" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import numpy as np
        import pandas as pd

        # Load exact trained model weights and biases
        coefs = [np.array(c, dtype=np.float32) for c in py_model_params["coefs"]]
        intercepts = [np.array(i, dtype=np.float32) for i in py_model_params["intercepts"]]

        # Test sample: (1.25, -0.75)
        x = np.array([[1.25, -0.75]], dtype=np.float32)

        # Layer 1: ReLU
        h1 = np.maximum(0.0, x @ coefs[0] + intercepts[0])
        # Layer 2: ReLU
        h2 = np.maximum(0.0, h1 @ coefs[1] + intercepts[1])
        # Layer 3: Linear Output
        res = h2 @ coefs[2] + intercepts[2]

        py_predict = pd.DataFrame({
            "prediction": [float(res[0][0])]
        })
EOF
      echo "    __node_result = py_predict" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  verify_node = stdenv.mkDerivation {
    name = "verify_node";
    buildInputs = [ tBin py_predict t_predict ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_py_predict = py_predict;
    T_INPUT_py_predict = "${py_predict}/artifact";
    T_NODE_t_predict = t_predict;
    T_INPUT_t_predict = "${t_predict}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_py_predict=${py_predict}
      export T_INPUT_py_predict=${py_predict}/artifact
      export T_NODE_t_predict=${t_predict}
      export T_INPUT_t_predict=${t_predict}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_py_predict/class\") && (read_file(\"$T_NODE_py_predict/class\") == \"VError\" || read_file(\"$T_NODE_py_predict/class\") == \"VError\\n\" || read_file(\"$T_NODE_py_predict/class\") == \"Error\" || read_file(\"$T_NODE_py_predict/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_py_predict = deserialize(\"$T_NODE_py_predict/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_py_predict = read_csv(\"$T_NODE_py_predict/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_t_predict/class\") && (read_file(\"$T_NODE_t_predict/class\") == \"VError\" || read_file(\"$T_NODE_t_predict/class\") == \"VError\\n\" || read_file(\"$T_NODE_t_predict/class\") == \"Error\" || read_file(\"$T_NODE_t_predict/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_t_predict = deserialize(\"$T_NODE_t_predict/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_t_predict = read_csv(\"$T_NODE_t_predict/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
t_predict = __dep_t_predict
EOF
      cat <<'EOF' >> node_script.t
py_predict = __dep_py_predict
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
print("--- ONNX JULIA END-TO-END STRESS TEST ---")
        t_val = pull(t_predict, "prediction")
        py_val = pull(py_predict, "prediction")
        print("Predictions:")
        print("  T-Native (ONNX serialized by Julia):")
        print(t_val)
        print("  Python (Scikit-Learn exact math):")
        print(py_val)
        -- Verify perfect numeric agreement within precision tolerance
        t_diff = (t_val .- py_val) |> abs() |> max()
        print("Parity Difference (T vs Python):")
        print(t_diff)
        assert(t_diff < 0.0001, "T-Native prediction should match Python prediction")
        "ONNX Julia End-to-End Stress Test Passed successfully!"
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin synthetic_data py_model_params py_model julia_model t_predict py_predict verify_node projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${synthetic_data} $out/synthetic_data
      cp -r ${py_model_params} $out/py_model_params
      cp -r ${py_model} $out/py_model
      cp -r ${julia_model} $out/julia_model
      cp -r ${t_predict} $out/t_predict
      cp -r ${py_predict} $out/py_predict
      cp -r ${verify_node} $out/verify_node
    '';
  };
}

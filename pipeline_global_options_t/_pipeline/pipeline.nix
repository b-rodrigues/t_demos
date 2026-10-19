
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
  
    rSerializerPackages = [ "arrow" "dplyr" "jsonlite" ];
    pySerializerPackages = [  ];
  rPackagesList = (toml.r-dependencies or {}).packages or [];
    rRenvPackagesList = [  ];
    rGitPkgSet = {};
  rGitPkgsList = builtins.attrValues rGitPkgSet;
  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = "python313";
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

  raw = stdenv.mkDerivation {
    name = "raw";
    buildInputs = [ tBin  ] ++ globalBuildInputs;
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

      cat << EOF > node_script.t

EOF














      cat <<'EOF' >> node_script.t
      __node_result = read_csv("data/sample.csv")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  heavy_r = pkgs.runCommand "heavy_r" {} ''
    mkdir -p $out
    echo "Build skipped for heavy_r" > $out/NOOPBUILD
  '';

  heavy_py = stdenv.mkDerivation {
    name = "heavy_py";
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

def _tlang_sanitize_json(v):
    import math as _tlang_math
    if isinstance(v, bool):
        return v
    if isinstance(v, float):
        return v if _tlang_math.isfinite(v) else None
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            sx = _tlang_sanitize_json(x)
            if sx is not None:
                out[k] = sx
        return out
    if isinstance(v, (list, tuple)):
        out = []
        for x in v:
            sx = _tlang_sanitize_json(x)
            if sx is not None:
                out.append(sx)
        return out
    return v

def py_save_meta(obj, path):
    try:
        import json as _tlang_json
        meta = {}
        cls = type(obj)
        meta["class"] = cls.__name__
        mod = getattr(cls, "__module__", "") or ""
        shape = getattr(obj, "shape", None)
        frame_2d = False
        try:
            frame_2d = (mod.startswith("pandas") or mod.startswith("polars")) and shape is not None and len(shape) == 2
        except Exception:
            frame_2d = False
        if frame_2d:
            meta["kind"] = "dataframe"
            meta["dimensions"] = [int(shape[0]), int(shape[1])]
            try:
                meta["features"] = [str(c) for c in list(obj.columns)]
            except Exception:
                pass
        elif (mod.startswith("pyarrow") and cls.__name__ == "Table"):
            meta["kind"] = "dataframe"
            try:
                meta["dimensions"] = [int(obj.num_rows), int(obj.num_columns)]
            except Exception:
                pass
            try:
                meta["features"] = [str(c) for c in list(obj.column_names)]
            except Exception:
                pass
        elif mod.startswith("sklearn") or (mod.startswith("lightgbm") and cls.__name__ not in ("Booster", "Dataset")):
            meta["kind"] = "model"
            est_type = None
            try:
                tags_fn = getattr(obj, "__sklearn_tags__", None)
                if callable(tags_fn):
                    est_type = getattr(tags_fn(), "estimator_type", None)
            except Exception:
                est_type = None
            if est_type is None:
                try:
                    est_type = getattr(obj, "_estimator_type", None)
                except Exception:
                    est_type = None
            if est_type == "classifier":
                meta["task"] = "classification"
            elif est_type == "regressor":
                meta["task"] = "regression"
            elif est_type == "clusterer":
                meta["task"] = "clustering"
            elif est_type == "density_estimator":
                meta["task"] = "density"
            elif est_type == "outlier_detector":
                meta["task"] = "anomaly_detection"
            elif est_type == "ranker" or "Ranker" in cls.__name__:
                meta["task"] = "ranking"
            elif "task" not in meta and any(k in cls.__name__ for k in ("PCA", "TruncatedSVD", "NMF", "FactorAnalysis")):
                meta["task"] = "dim_reduction"
            if "task" not in meta:
                try:
                    tags_fn2 = getattr(obj, "__sklearn_tags__", None)
                    if callable(tags_fn2):
                        ttags = getattr(tags_fn2(), "transformer_tags", None)
                        if ttags is not None:
                            meta["kind"] = "transformer"
                except Exception:
                    pass
            n_feat = getattr(obj, "n_features_in_", None)
            if n_feat is not None:
                try:
                    meta["n_features"] = int(n_feat)
                except Exception:
                    pass
            else:
                try:
                    coef = getattr(obj, "coef_", None)
                    if coef is not None:
                        cshape = getattr(coef, "shape", None)
                        if cshape is not None and len(cshape) >= 1:
                            meta["n_features"] = int(cshape[-1])
                except Exception:
                    pass
            try:
                feats = getattr(obj, "feature_names_in_", None)
                if feats is not None:
                    meta["features"] = [str(f) for f in list(feats)]
            except Exception:
                pass
            try:
                classes = getattr(obj, "classes_", None)
                if classes is not None:
                    meta.setdefault("metrics", {})["n_classes"] = int(len(list(classes)))
            except Exception:
                pass
            try:
                bi = getattr(obj, "best_iteration", None)
                if bi is None:
                    bi = getattr(obj, "best_iteration_", None)
                if bi is not None:
                    meta.setdefault("metrics", {})["best_iteration"] = int(bi)
            except Exception:
                pass
            try:
                cc = getattr(obj, "cluster_centers_", None)
                if cc is not None:
                    meta["n_clusters"] = int(len(cc))
                else:
                    nc = getattr(obj, "n_clusters_", None)
                    if nc is not None:
                        meta["n_clusters"] = int(nc)
                    else:
                        lab = getattr(obj, "labels_", None)
                        if lab is not None:
                            uniq = set()
                            for v in list(lab):
                                try:
                                    iv = int(v)
                                except Exception:
                                    continue
                                if iv != -1:
                                    uniq.add(iv)
                            meta["n_clusters"] = len(uniq)
            except Exception:
                pass
            try:
                iner = getattr(obj, "inertia_", None)
                if iner is not None:
                    meta.setdefault("metrics", {})["inertia"] = float(iner)
            except Exception:
                pass
            try:
                evr = getattr(obj, "explained_variance_ratio_", None)
                if evr is not None:
                    ev = [float(v) for v in list(evr)]
                    if ev:
                        meta["n_components"] = len(ev)
                        meta.setdefault("metrics", {})["var_first"] = ev[0]
            except Exception:
                pass
            try:
                nc = getattr(obj, "n_components", None)
                if nc is not None and "n_components" not in meta:
                    meta["n_components"] = int(nc)
            except Exception:
                pass
            try:
                bs = getattr(obj, "best_score_", None)
                if bs is not None:
                    meta.setdefault("metrics", {})["best_score"] = float(bs)
            except Exception:
                pass
            try:
                lb = getattr(obj, "lower_bound_", None)
                if lb is not None:
                    meta.setdefault("metrics", {})["lower_bound"] = float(lb)
            except Exception:
                pass
            try:
                bb = getattr(obj, "booster_", None)
                if bb is not None and "n_rounds" not in meta:
                    try:
                        rounds = int(bb.current_iteration())
                    except Exception:
                        rounds = None
                    if rounds is None:
                        try:
                            per = int(bb.num_model_per_iteration())
                            if per > 0:
                                rounds = int(bb.num_trees()) // per
                        except Exception:
                            rounds = None
                    if rounds is None:
                        try:
                            rounds = int(bb.num_trees())
                        except Exception:
                            rounds = None
                    if rounds is not None:
                        meta["n_rounds"] = rounds
            except Exception:
                pass
        elif mod.startswith("xgboost"):
            if cls.__name__ == "Booster":
                meta["kind"] = "model"
                try:
                    import json as _tlang_cfg_json
                    cfg = _tlang_cfg_json.loads(obj.save_config())
                    oname = ((cfg.get("learner", {}).get("objective", {}) or {}).get("name", "") or "")
                    if any(k in oname for k in ("binary", "multi", "softmax")):
                        meta["task"] = "classification"
                    elif any(k in oname for k in ("reg:", "squarederror", "gamma", "tweedie")):
                        meta["task"] = "regression"
                except Exception:
                    pass
                try:
                    rounds = None
                    try:
                        rounds = int(obj.num_boosted_rounds())
                    except Exception:
                        rounds = None
                    if rounds is None:
                        try:
                            rounds = int(obj.current_iteration())
                        except Exception:
                            rounds = None
                    if rounds is None:
                        try:
                            per = int(obj.num_model_per_iteration())
                            if per > 0:
                                rounds = int(obj.num_trees()) // per
                        except Exception:
                            rounds = None
                    if rounds is None:
                        try:
                            rounds = int(obj.num_trees())
                        except Exception:
                            rounds = None
                    if rounds is not None:
                        meta["n_rounds"] = rounds
                except Exception:
                    pass
                try:
                    nf = obj.num_features()
                    if nf is not None:
                        meta["n_features"] = int(nf)
                except Exception:
                    pass
                try:
                    fnames = obj.feature_names
                    if fnames is not None:
                        meta["features"] = [str(f) for f in list(fnames)]
                except Exception:
                    pass
            elif cls.__name__ == "DMatrix":
                meta["kind"] = "data"
                try:
                    meta["dimensions"] = [int(obj.num_row()), int(obj.num_col())]
                except Exception:
                    pass
                try:
                    fnames = getattr(obj, "feature_names", None)
                    if fnames is not None:
                        meta["features"] = [str(f) for f in list(fnames)]
                except Exception:
                    pass
            else:
                meta["kind"] = "model"
                try:
                    tags_fn = getattr(obj, "__sklearn_tags__", None)
                    if callable(tags_fn):
                        est_type = getattr(tags_fn(), "estimator_type", None)
                        if est_type == "classifier":
                            meta["task"] = "classification"
                        elif est_type == "regressor":
                            meta["task"] = "regression"
                        elif est_type == "ranker" or "Ranker" in cls.__name__:
                            meta["task"] = "ranking"
                except Exception:
                    pass
                if "task" not in meta and ("Ranker" in cls.__name__):
                    meta["task"] = "ranking"
                try:
                    gb = getattr(obj, "get_booster", lambda: None)()
                    if gb is not None:
                        try:
                            meta["n_rounds"] = int(gb.num_boosted_rounds())
                        except Exception:
                            pass
                        try:
                            nf = gb.num_features()
                            if nf is not None and "n_features" not in meta:
                                meta["n_features"] = int(nf)
                        except Exception:
                            pass
                except Exception:
                    pass
                try:
                    nf = getattr(obj, "n_features_in_", None)
                    if nf is not None:
                        meta["n_features"] = int(nf)
                except Exception:
                    pass
                try:
                    feats = getattr(obj, "feature_names_in_", None)
                    if feats is not None:
                        meta["features"] = [str(f) for f in list(feats)]
                except Exception:
                    pass
                try:
                    classes = getattr(obj, "classes_", None)
                    if classes is not None:
                        meta.setdefault("metrics", {})["n_classes"] = int(len(list(classes)))
                except Exception:
                    pass
                try:
                    bi = getattr(obj, "best_iteration", None)
                    if bi is None:
                        bi = getattr(obj, "best_iteration_", None)
                    if bi is not None:
                        meta.setdefault("metrics", {})["best_iteration"] = int(bi)
                except Exception:
                    pass
        elif mod.startswith("lightgbm"):
            if cls.__name__ == "Dataset":
                meta["kind"] = "data"
                try:
                    meta["dimensions"] = [int(obj.num_data()), int(obj.num_feature())]
                except Exception:
                    pass
            else:
                meta["kind"] = "model"
                try:
                    prm = getattr(obj, "params", None)
                    if isinstance(prm, dict):
                        oname = str(prm.get("objective", "") or "")
                        if any(k in oname for k in ("binary", "multiclass", "softmax")):
                            meta["task"] = "classification"
                        elif any(k in oname for k in ("regression", "poisson", "gamma", "tweedie")):
                            meta["task"] = "regression"
                except Exception:
                    pass
                try:
                    rounds = None
                    try:
                        rounds = int(obj.current_iteration())
                    except Exception:
                        rounds = None
                    if rounds is None:
                        try:
                            per = int(obj.num_model_per_iteration())
                            if per > 0:
                                rounds = int(obj.num_trees()) // per
                        except Exception:
                            rounds = None
                    if rounds is None:
                        try:
                            rounds = int(obj.num_trees())
                        except Exception:
                            rounds = None
                    if rounds is not None:
                        meta["n_rounds"] = rounds
                except Exception:
                    pass
                try:
                    nf = obj.num_feature()
                    if nf is not None:
                        meta["n_features"] = int(nf)
                except Exception:
                    pass
                try:
                    fnames = obj.feature_name()
                    if fnames is not None:
                        meta["features"] = [str(f) for f in list(fnames)]
                except Exception:
                    pass
        elif mod.startswith("statsmodels"):
            meta["kind"] = "model"
            order = None
            try:
                model = getattr(obj, "model", None)
                if model is not None:
                    o = getattr(model, "order", None)
                    if o is not None:
                        order = [int(v) for v in list(o)]
            except Exception:
                order = None
            if order is not None:
                meta["task"] = "time_series"
                meta["order"] = order
                try:
                    so = getattr(obj.model, "seasonal_order", None)
                    if so is not None:
                        so_list = [int(v) for v in list(so)]
                        if len(so_list) == 4 and so_list[3] > 1 and any(v > 0 for v in so_list[:3]):
                            meta["seasonal_order"] = so_list
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    if "Regression" in cls.__name__:
                        meta["task"] = "regression"
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    if "MixedLM" in cls.__name__:
                        meta["task"] = "regression"
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    if "MNLogit" in cls.__name__ or "Multinomial" in cls.__name__:
                        meta["task"] = "classification"
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    if "PHReg" in cls.__name__:
                        meta["task"] = "survival"
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    if "VAR" in cls.__name__:
                        meta["task"] = "time_series"
                except Exception:
                    pass
            try:
                kar = getattr(getattr(obj, "model", None), "k_ar", None)
                if kar is not None and "order" not in meta:
                    meta["order"] = [int(kar)]
            except Exception:
                pass
            if "task" not in meta:
                try:
                    fam = getattr(getattr(obj, "model", None), "family", None)
                    fname = type(fam).__name__ if fam is not None else ""
                    if "Binomial" in fname or "Bernoulli" in fname:
                        meta["task"] = "classification"
                    elif "Gaussian" in fname or "Normal" in fname or "Poisson" in fname or "Gamma" in fname:
                        meta["task"] = "regression"
                except Exception:
                    pass
            if "task" not in meta:
                try:
                    mname = type(getattr(obj, "model", None)).__name__
                    if "Logit" in mname or "Probit" in mname:
                        meta["task"] = "classification"
                except Exception:
                    pass
            try:
                n = getattr(obj, "nobs", None)
                if n is not None:
                    meta["n_obs"] = int(n)
            except Exception:
                pass
            try:
                params = getattr(obj, "params", None)
                if isinstance(params, dict):
                    pass
                elif params is not None:
                    names = None
                    # Multinomial outcomes sit in columns; predictors are the index.
                    is_mnlogit = False
                    try:
                        is_mnlogit = "MNLogit" in cls.__name__ or "Multinomial" in cls.__name__
                    except Exception:
                        pass
                    if not is_mnlogit:
                        try:
                            cols = getattr(params, "columns", None)
                            if cols is not None:
                                names = [str(v) for v in list(cols)]
                        except Exception:
                            names = None
                    if names is None:
                        try:
                            idx = getattr(params, "index", None)
                            if idx is not None:
                                names = [str(v) for v in list(idx) if str(v) not in ("Intercept", "const")]
                        except Exception:
                            names = None
                    if names:
                        meta["n_features"] = len(names)
                        meta["features"] = names
                    else:
                        try:
                            meta["n_features"] = int(len(params))
                        except Exception:
                            pass
            except Exception:
                pass
            if "task" not in meta:
                try:
                    if "HoltWinters" in cls.__name__ or "ETS" in cls.__name__:
                        meta["task"] = "time_series"
                except Exception:
                    pass
            for _mkey, _mattr in (("aic", "aic"), ("bic", "bic"), ("loglik", "llf"),
                                   ("r_squared", "rsquared"), ("deviance", "deviance")):
                try:
                    _mv = getattr(obj, _mattr, None)
                    if _mv is not None:
                        meta.setdefault("metrics", {})[_mkey] = float(_mv)
                except Exception:
                    pass
            try:
                _groups = getattr(getattr(obj, "model", None), "groups", None)
                if _groups is not None:
                    import numpy as _tlang_np
                    _u, _c = _tlang_np.unique(_tlang_np.asarray(_groups, dtype=str), return_counts=True)
                    _names = [str(v) for v in list(_u)]
                    _counts = [int(v) for v in list(_c)]
                    if _names:
                        meta["n_groups"] = len(_names)
                        if len(_names) <= 50:
                            meta["groups"] = dict(zip(_names, _counts))
            except Exception:
                pass
        elif mod.startswith("scipy") and getattr(obj, "shape", None) is None:
            st = getattr(obj, "statistic", None)
            pv = getattr(obj, "pvalue", None)
            if st is not None and pv is not None:
                meta["kind"] = "test"
                try:
                    meta.setdefault("metrics", {})["statistic"] = float(st)
                except Exception:
                    pass
                try:
                    meta.setdefault("metrics", {})["p_value"] = float(pv)
                except Exception:
                    pass
            elif "frozen" in cls.__name__:
                meta["kind"] = "distribution"
                try:
                    d = getattr(obj, "dist", None)
                    dn = getattr(d, "name", None) if d is not None else None
                    if dn:
                        meta["method"] = str(dn)
                except Exception:
                    pass
                try:
                    meta.setdefault("metrics", {})["mean"] = float(obj.mean())
                except Exception:
                    pass
                try:
                    meta.setdefault("metrics", {})["std"] = float(obj.std())
                except Exception:
                    pass
            else:
                meta["kind"] = "other"
        elif shape is not None:
            try:
                dims = [int(v) for v in list(shape)]
            except Exception:
                dims = None
            dtype = None
            try:
                dt = getattr(obj, "dtype", None)
                if dt is not None:
                    dtype = getattr(dt, "name", None) or str(dt)
            except Exception:
                dtype = None
            if dims is None:
                meta["kind"] = "other"
            elif len(dims) == 2:
                meta["kind"] = "matrix"
                meta["dimensions"] = dims
                if dtype is not None:
                    meta["dtype"] = dtype
            elif len(dims) == 1:
                meta["kind"] = "vector"
                meta["dimensions"] = dims
                if dtype is not None:
                    meta["dtype"] = dtype
            elif len(dims) > 2:
                meta["kind"] = "array"
                meta["dimensions"] = dims
                if dtype is not None:
                    meta["dtype"] = dtype
            else:
                meta["kind"] = "other"
            try:
                nnz = getattr(obj, "nnz", None)
                if nnz is not None and meta.get("kind") in ("matrix", "vector", "array"):
                    meta.setdefault("metrics", {})["nnz"] = int(nnz)
            except Exception:
                pass
        else:
            meta["kind"] = "other"
        try:
            _feats = meta.get("features")
            if isinstance(_feats, list) and len(_feats) > 500:
                meta["features"] = _feats[:500]
        except Exception:
            pass
        meta = _tlang_sanitize_json(meta)
        with open(path, "w") as f:
            _tlang_json.dump(meta, f, default=str)
    except Exception:
        try:
            import json as _tlang_json2
            with open(path, "w") as f:
                _tlang_json2.dump({"kind": "unknown"}, f)
        except Exception:
            pass

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





      echo "def __node_runner():" >> node_script.py
      cat <<'EOF' >> node_script.py
    return {"status": "ok"}
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
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  say_hi = stdenv.mkDerivation {
    name = "say_hi";
    buildInputs = [ tBin pkgs.bash ] ++ globalBuildInputs;
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

      cat << EOF > node_script.sh

EOF














      cat <<'EOF' >> node_script.sh
echo hi
EOF
      mkdir -p $out
      env -i HOME="$TMPDIR" PATH="$PATH" TMPDIR="$TMPDIR" 'sh' 'node_script.sh' > $out/artifact
      echo ShellOutput > $out/class
    '';
  };
 

  report = stdenv.mkDerivation {
    name = "report";
    buildInputs = [ tBin raw ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_raw = raw;
    T_INPUT_raw = "${raw}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw=${raw}
      export T_INPUT_raw=${raw}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_raw/class\") && (read_file(\"$T_NODE_raw/class\") == \"VError\" || read_file(\"$T_NODE_raw/class\") == \"VError\\n\" || read_file(\"$T_NODE_raw/class\") == \"Error\" || read_file(\"$T_NODE_raw/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_raw = deserialize(\"$T_NODE_raw/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_raw = read_ipc(\"$T_NODE_raw/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
raw = __dep_raw
EOF

      cat <<'EOF' >> node_script.t
      __node_result = (nrow(raw) > 0)
EOF
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
    buildInputs = [ tBin raw heavy_r heavy_py say_hi report projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw} $out/raw
      cp -r ${heavy_r} $out/heavy_r
      cp -r ${heavy_py} $out/heavy_py
      cp -r ${say_hi} $out/say_hi
      cp -r ${report} $out/report
    '';
  };
}

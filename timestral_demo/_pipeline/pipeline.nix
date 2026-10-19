
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
  
    rSerializerPackages = [ "forecast" "jsonlite" "knitr" "rmarkdown" "vars" ];
    pySerializerPackages = [ "ipykernel" "nbclient" "nbformat" "pandas" "pyyaml" ];
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

  helpers = stdenv.mkDerivation {
    name = "helpers";
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
      __node_result = [code: read_file("src/helpers.R")]
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  raw_data = stdenv.mkDerivation {
    name = "raw_data";
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
      __node_result = read_csv("data/cpi.csv", separator = ",")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_csv(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  r_arima = stdenv.mkDerivation {
    name = "r_arima";
    buildInputs = [ tBin r-env helpers raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_raw_data = raw_data;
    T_INPUT_raw_data = "${raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_raw_data=${raw_data}
      export T_INPUT_raw_data=${raw_data}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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







      cat <<'EOF' >> node_script.R
library(forecast)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_raw_data <- r_read_json(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_raw_data <- r_read_csv(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "raw_data <- dep_raw_data" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      stopifnot(is.character(helpers$code), nchar(paste(helpers$code, collapse = "")) > 0)
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      train_cpi = head(raw_data$cpi, -12)
      ts_train  = ts(train_cpi, frequency = 12)
      last_val  = tail(train_cpi, 1)
      fc_naive = rep(last_val, 12)
      q_naive  = forecast_quantiles("naive", h = 12, y_train = train_cpi)
      fc_drift = as.numeric(rwf(ts_train, h = 12, drift = TRUE)$mean)
      q_drift  = forecast_quantiles("drift", h = 12, y_train = train_cpi)
      fit_arima  = auto.arima(ts_train, seasonal = TRUE)
      fc_arima   = as.numeric(forecast(fit_arima, h = 12)$mean)
      q_arima    = forecast_quantiles(fit_arima, h = 12)
      arima_spec = paste0("ARIMA(", paste(arimaorder(fit_arima), collapse = ","), ")")
      fit_ets    = ets(ts_train)
      fc_ets     = as.numeric(forecast(fit_ets, h = 12)$mean)
      q_ets      = forecast_quantiles(fit_ets, h = 12, npaths = 3000, seed = 2024)
      ets_spec   = fit_ets$method
      fc_ens     = (fc_arima + fc_ets) / 2
      q_ens      = 0.5 * (q_arima + q_ets)
      out = data.frame(
        step       = 1:12,
        naive      = fc_naive,
        drift      = fc_drift,
        arima      = fc_arima,
        arima_spec = rep(arima_spec, 12),
        ets        = fc_ets,
        ets_spec   = rep(ets_spec, 12),
        ensemble   = fc_ens
      )
      for (cn in colnames(q_arima)) {
        out[[paste0("nai_", cn)]] = q_naive[, cn]
        out[[paste0("dri_", cn)]] = q_drift[, cn]
        out[[paste0("ari_", cn)]] = q_arima[, cn]
        out[[paste0("ets_", cn)]] = q_ets[, cn]
        out[[paste0("ens_", cn)]] = q_ens[, cn]
      }
      r_arima = out
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  timestral_5m = stdenv.mkDerivation {
    name = "timestral_5m";
    buildInputs = [ tBin py-env raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_raw_data = raw_data;
    T_INPUT_raw_data = "${raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}
      export T_INPUT_raw_data=${raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_raw_data = py_read_json(os.path.join(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_raw_data = py_read_csv(os.path.join(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.py
      echo "raw_data = __dep_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        cpi_vals = raw_data["cpi"].values[:-12].copy()
        fc = TimestralForecaster.from_pretrained("models/Timestral-5M")
        res = fc.forecast(cpi_vals, prediction_length=12)
        preds = res.median.cpu().numpy().squeeze().tolist()
        q_mat = res.quantiles.cpu().numpy().squeeze()
        q_levels = list(res.quantile_levels)

        data_dict = {"step": list(range(1, 13)), "timestral_5m": preds}
        for i, lvl in enumerate(q_levels):
            col_name = f"q_{int(round(lvl * 100)):02d}"
            data_dict[col_name] = q_mat[:, i].tolist()

        timestral_5m = pd.DataFrame(data_dict)
EOF
      echo "    __node_result = timestral_5m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  timestral_209m = stdenv.mkDerivation {
    name = "timestral_209m";
    buildInputs = [ tBin py-env raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_raw_data = raw_data;
    T_INPUT_raw_data = "${raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}
      export T_INPUT_raw_data=${raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_raw_data = py_read_json(os.path.join(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_raw_data = py_read_csv(os.path.join(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.py
      echo "raw_data = __dep_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        cpi_vals = raw_data["cpi"].values[:-12].copy()
        fc = TimestralForecaster.from_pretrained("models/Timestral-209M")
        res = fc.forecast(cpi_vals, prediction_length=12)
        preds = res.median.cpu().numpy().squeeze().tolist()
        q_mat = res.quantiles.cpu().numpy().squeeze()
        q_levels = list(res.quantile_levels)

        data_dict = {"step": list(range(1, 13)), "timestral_209m": preds}
        for i, lvl in enumerate(q_levels):
            col_name = f"q_{int(round(lvl * 100)):02d}"
            data_dict[col_name] = q_mat[:, i].tolist()

        timestral_209m = pd.DataFrame(data_dict)
EOF
      echo "    __node_result = timestral_209m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  benchmark_metrics = stdenv.mkDerivation {
    name = "benchmark_metrics";
    buildInputs = [ tBin r-env helpers r_arima raw_data timestral_209m timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_r_arima = r_arima;
    T_INPUT_r_arima = "${r_arima}/artifact";
    T_NODE_raw_data = raw_data;
    T_INPUT_raw_data = "${raw_data}/artifact";
    T_NODE_timestral_209m = timestral_209m;
    T_INPUT_timestral_209m = "${timestral_209m}/artifact";
    T_NODE_timestral_5m = timestral_5m;
    T_INPUT_timestral_5m = "${timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_r_arima=${r_arima}
      export T_INPUT_r_arima=${r_arima}/artifact
      export T_NODE_raw_data=${raw_data}
      export T_INPUT_raw_data=${raw_data}/artifact
      export T_NODE_timestral_209m=${timestral_209m}
      export T_INPUT_timestral_209m=${timestral_209m}/artifact
      export T_NODE_timestral_5m=${timestral_5m}
      export T_INPUT_timestral_5m=${timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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








      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_r_arima\", \"class\")) && readLines(file.path(\"$T_NODE_r_arima\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_r_arima <- r_read_json(file.path(\"$T_NODE_r_arima\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_r_arima <- r_read_csv(file.path(\"$T_NODE_r_arima\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_raw_data <- r_read_json(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_raw_data <- r_read_csv(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_timestral_209m <- r_read_json(file.path(\"$T_NODE_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_timestral_209m <- r_read_csv(file.path(\"$T_NODE_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_timestral_5m <- r_read_json(file.path(\"$T_NODE_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_timestral_5m <- r_read_csv(file.path(\"$T_NODE_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "r_arima <- dep_r_arima" >> node_script.R
      echo "raw_data <- dep_raw_data" >> node_script.R
      echo "timestral_209m <- dep_timestral_209m" >> node_script.R
      echo "timestral_5m <- dep_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(raw_data$cpi, 12)
      last_train = tail(head(raw_data$cpi, -12), 1)
      calc_inf <- function(pred) (tail(pred, 1) - last_train) / last_train * 100
      ari_spec = as.character(r_arima$arima_spec[1])
      ets_spec = as.character(r_arima$ets_spec[1])
      models_list = list(
        list(name = "Naive (Marche aléatoire)",  spec = "RW(0)",                   pred = r_arima$naive),
        list(name = "RW avec Dérive (Drift)",     spec = "RW+drift",                pred = r_arima$drift),
        list(name = "R ARIMA (AIC)",              spec = ari_spec,                  pred = r_arima$arima),
        list(name = "R ETS (Espace d${"'"}états)",     spec = ets_spec,                  pred = r_arima$ets),
        list(name = "R Ensemble (ARIMA+ETS)",     spec = paste0(ari_spec, "+", ets_spec), pred = r_arima$ensemble),
        list(name = "Timestral-5M (Zero-shot)",   spec = "Patch=32, 5M, L=168",     pred = timestral_5m$timestral_5m),
        list(name = "Timestral-209M (Zero-shot)", spec = "Patch=32, 209M, L=168",   pred = timestral_209m$timestral_209m)
      )
      naive_rmse = rmse(r_arima$naive, actual)
      actual_inf = round((tail(actual, 1) - last_train) / last_train * 100, 2)
      rows = lapply(models_list, function(m) {
        m_rmse = rmse(m$pred, actual)
        data.frame(
          model             = m$name,
          specification     = m$spec,
          rmse              = round(m_rmse, 4),
          mae               = round(mae(m$pred, actual), 4),
          relative_rmse     = round(m_rmse / naive_rmse, 3),
          implied_inflation = round(calc_inf(m$pred), 2),
          actual_inflation  = actual_inf
        )
      })
      benchmark_metrics = do.call(rbind, rows)
      rownames(benchmark_metrics) <- NULL
      benchmark_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  cpi_probabilistic_metrics = stdenv.mkDerivation {
    name = "cpi_probabilistic_metrics";
    buildInputs = [ tBin r-env helpers r_arima raw_data timestral_209m timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_r_arima = r_arima;
    T_INPUT_r_arima = "${r_arima}/artifact";
    T_NODE_raw_data = raw_data;
    T_INPUT_raw_data = "${raw_data}/artifact";
    T_NODE_timestral_209m = timestral_209m;
    T_INPUT_timestral_209m = "${timestral_209m}/artifact";
    T_NODE_timestral_5m = timestral_5m;
    T_INPUT_timestral_5m = "${timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_r_arima=${r_arima}
      export T_INPUT_r_arima=${r_arima}/artifact
      export T_NODE_raw_data=${raw_data}
      export T_INPUT_raw_data=${raw_data}/artifact
      export T_NODE_timestral_209m=${timestral_209m}
      export T_INPUT_timestral_209m=${timestral_209m}/artifact
      export T_NODE_timestral_5m=${timestral_5m}
      export T_INPUT_timestral_5m=${timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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








      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_r_arima\", \"class\")) && readLines(file.path(\"$T_NODE_r_arima\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_r_arima <- r_read_json(file.path(\"$T_NODE_r_arima\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_r_arima <- r_read_csv(file.path(\"$T_NODE_r_arima\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_raw_data <- r_read_json(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_raw_data <- r_read_csv(file.path(\"$T_NODE_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_timestral_209m <- r_read_json(file.path(\"$T_NODE_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_timestral_209m <- r_read_csv(file.path(\"$T_NODE_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_timestral_5m <- r_read_json(file.path(\"$T_NODE_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_timestral_5m <- r_read_csv(file.path(\"$T_NODE_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "r_arima <- dep_r_arima" >> node_script.R
      echo "raw_data <- dep_raw_data" >> node_script.R
      echo "timestral_209m <- dep_timestral_209m" >> node_script.R
      echo "timestral_5m <- dep_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(raw_data$cpi, 12)
      q_cols = quantile_cols(timestral_5m)
      stopifnot(check_grid(q_cols), identical(q_cols, quantile_cols(timestral_209m)))
      get_m <- function(df, prefix) {
        m = as.matrix(df[, paste0(prefix, q_cols)])
        colnames(m) = q_cols
        m
      }
      nai_q   = get_m(r_arima, "nai_")
      dri_q   = get_m(r_arima, "dri_")
      ari_q   = get_m(r_arima, "ari_")
      ets_q   = get_m(r_arima, "ets_")
      ens_q   = get_m(r_arima, "ens_")
      t5m_q   = as.matrix(timestral_5m[, q_cols])
      t209m_q = as.matrix(timestral_209m[, q_cols])
      ari_spec = as.character(r_arima$arima_spec[1])
      ets_spec = as.character(r_arima$ets_spec[1])
      sc_nai = summarise_scores(score_rows(actual, nai_q))
      sc_dri = summarise_scores(score_rows(actual, dri_q))
      sc_ari = summarise_scores(score_rows(actual, ari_q))
      sc_ets = summarise_scores(score_rows(actual, ets_q))
      sc_ens = summarise_scores(score_rows(actual, ens_q))
      sc_t5  = summarise_scores(score_rows(actual, t5m_q))
      sc_t20 = summarise_scores(score_rows(actual, t209m_q))
      nai_wis = sc_nai$wis[1]
      prob_list = list(
        cbind(data.frame(model = "Naive (Marche aléatoire)", dist_method = "RW gaussien (innovations 1-pas)", scaled_wis = 1.000), sc_nai),
        cbind(data.frame(model = "RW avec Dérive (Drift)",    dist_method = "RW+dérive gaussien",             scaled_wis = round(sc_dri$wis / nai_wis, 3)), sc_dri),
        cbind(data.frame(model = "R ARIMA",                  dist_method = paste0(ari_spec, " (analytique)"), scaled_wis = round(sc_ari$wis / nai_wis, 3)), sc_ari),
        cbind(data.frame(model = "R ETS",                    dist_method = paste0(ets_spec, " (simulé, B=3000)"), scaled_wis = round(sc_ets$wis / nai_wis, 3)), sc_ets),
        cbind(data.frame(model = "R Ensemble",               dist_method = "Moyenne de quantiles (ARIMA+ETS)", scaled_wis = round(sc_ens$wis / nai_wis, 3)), sc_ens),
        cbind(data.frame(model = "Timestral-5M",             dist_method = "21 quantiles natifs (L=168)",     scaled_wis = round(sc_t5$wis / nai_wis, 3)), sc_t5),
        cbind(data.frame(model = "Timestral-209M",           dist_method = "21 quantiles natifs (L=168)",     scaled_wis = round(sc_t20$wis / nai_wis, 3)), sc_t20)
      )
      cpi_probabilistic_metrics = do.call(rbind, prob_list)
      rownames(cpi_probabilistic_metrics) <- NULL
      cpi_probabilistic_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  retail_raw_data = stdenv.mkDerivation {
    name = "retail_raw_data";
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
      __node_result = read_csv("data/retail_sales.csv", separator = ",")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_csv(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  retail_r_arima = stdenv.mkDerivation {
    name = "retail_r_arima";
    buildInputs = [ tBin r-env helpers retail_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_retail_raw_data = retail_raw_data;
    T_INPUT_retail_raw_data = "${retail_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_retail_raw_data=${retail_raw_data}
      export T_INPUT_retail_raw_data=${retail_raw_data}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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







      cat <<'EOF' >> node_script.R
library(forecast)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_retail_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_json(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_csv(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "retail_raw_data <- dep_retail_raw_data" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      train = head(retail_raw_data, -12)
      test  = tail(retail_raw_data, 12)
      for (nm in c("train", "test")) {
        d = get(nm)
        d$other = d$total - (d$automotive + d$food_beverage + d$clothing + d$ecommerce + d$general_merchandise)
        assign(nm, d)
      }
      sectors_5      = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise")
      sectors_all    = c("total", sectors_5, "other")
      sectors_bottom = c(sectors_5, "other")
      fcasts_ets = list()
      fcasts_ari = list()
      res_ets    = list()
      res_ari    = list()
      wis_ets    = numeric(length(sectors_all))
      wis_ari    = numeric(length(sectors_all))
      crps_ets   = numeric(length(sectors_all))
      crps_ari   = numeric(length(sectors_all))
      names(wis_ets) = names(wis_ari) = names(crps_ets) = names(crps_ari) = sectors_all
      for (s in sectors_all) {
        y_ts = ts(train[[s]], frequency = 12)
        act  = test[[s]]
        fit_e = ets(y_ts)
        fcasts_ets[[s]] = as.numeric(forecast(fit_e, h = 12)$mean)
        res_ets[[s]]    = as.numeric(residuals(fit_e, type = "response"))
        sc_e            = score_rows(act, forecast_quantiles(fit_e, h = 12, npaths = 2000, seed = 2024))
        wis_ets[s]      = mean(sc_e$wis)
        crps_ets[s]     = mean(sc_e$crps)
        fit_a = auto.arima(y_ts)
        fcasts_ari[[s]] = as.numeric(forecast(fit_a, h = 12)$mean)
        res_ari[[s]]    = as.numeric(residuals(fit_a, type = "response"))
        sc_a            = score_rows(act, forecast_quantiles(fit_a, h = 12))
        wis_ari[s]      = mean(sc_a$wis)
        crps_ari[s]     = mean(sc_a$crps)
      }
      S = rbind(rep(1, 6), diag(6))
      rownames(S) = sectors_all
      colnames(S) = sectors_bottom
      base_ets = do.call(cbind, fcasts_ets)
      base_ari = do.call(cbind, fcasts_ari)
      sh_ets   = shrink_cov(do.call(cbind, res_ets))
      sh_ari   = shrink_cov(do.call(cbind, res_ari))
      m_ets    = mint(base_ets, sh_ets$W, S)
      m_ari    = mint(base_ari, sh_ari$W, S)
      res = data.frame(
        step                     = 1:12,
        ets_lambda               = rep(sh_ets$lambda, 12),
        arima_lambda             = rep(sh_ari$lambda, 12),
        mint_ets_coherence_err   = rep(m_ets$coh_err, 12),
        mint_arima_coherence_err = rep(m_ari$coh_err, 12)
      )
      for (s in sectors_all) {
        res[[paste0("naive_", s)]]      = rep(tail(train[[s]], 1), 12)
        res[[paste0("arima_", s)]]      = base_ari[, s]
        res[[paste0("mint_arima_", s)]] = m_ari$rec[, s]
        res[[paste0("ets_", s)]]        = base_ets[, s]
        res[[paste0("mint_ets_", s)]]   = m_ets$rec[, s]
        res[[paste0("wis_ets_", s)]]    = rep(wis_ets[s], 12)
        res[[paste0("wis_arima_", s)]]  = rep(wis_ari[s], 12)
        res[[paste0("crps_ets_", s)]]   = rep(crps_ets[s], 12)
        res[[paste0("crps_arima_", s)]] = rep(crps_ari[s], 12)
      }
      retail_r_arima = res
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  retail_timestral_5m = stdenv.mkDerivation {
    name = "retail_timestral_5m";
    buildInputs = [ tBin py-env retail_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_retail_raw_data = retail_raw_data;
    T_INPUT_retail_raw_data = "${retail_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_retail_raw_data=${retail_raw_data}
      export T_INPUT_retail_raw_data=${retail_raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_retail_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_retail_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_retail_raw_data = py_read_json(os.path.join(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_retail_raw_data = py_read_csv(os.path.join(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.py
      echo "retail_raw_data = __dep_retail_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        train = retail_raw_data.iloc[:-12].copy()
        test  = retail_raw_data.iloc[-12:].copy()
        for d in (train, test):
            d["other"] = d["total"] - (d["automotive"] + d["food_beverage"] + d["clothing"] + d["ecommerce"] + d["general_merchandise"])

        sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
        fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

        # 1. Programmatic assertion: verify batch evaluation matches individual 1D calls up to float32 precision (rtol=1e-5, atol=0.1)
        mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
        test_sample = mat_train[:, :120].copy()
        batch_pred = fc.forecast(test_sample, prediction_length=1).median.cpu().numpy().squeeze()
        indiv_pred = np.array([fc.forecast(test_sample[idx], prediction_length=1).median.cpu().numpy().squeeze() for idx in range(len(sectors_all))])
        max_diff = float(np.max(np.abs(batch_pred - indiv_pred)))
        assert np.allclose(batch_pred, indiv_pred, rtol=1e-5, atol=0.1), f"Batch vs 1D parity failed for Timestral-5M: max diff is {max_diff}"

        # Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
        res_list = []
        for o in range(120, mat_train.shape[1]):
            p1 = fc.forecast(mat_train[:, :o].copy(), prediction_length=1).median.cpu().numpy().squeeze()
            res_list.append(mat_train[:, o] - p1)
        res_mat = np.stack(res_list, axis=0)  # (48, 7)

        # Correlation-standardized Schäfer-Strimmer shrinkage
        n = res_mat.shape[0]
        covm = (res_mat.T @ res_mat) / n
        tar = np.diag(np.diag(covm))
        sd = np.sqrt(np.diag(covm))
        corm = covm / np.outer(sd, sd)
        xs = res_mat / sd[np.newaxis, :]
        v = (1.0 / (n * (n - 1))) * ((xs ** 2).T @ (xs ** 2) - ((xs.T @ xs) ** 2) / n)
        np.fill_diagonal(v, 0.0)
        d_mat = (corm - np.eye(len(sectors_all))) ** 2
        lam = float(np.clip(np.sum(v) / np.sum(d_mat), 0.0, 1.0))
        W = lam * tar + (1.0 - lam) * covm
        S = np.vstack([np.ones((1, 6)), np.eye(6)])
        Wi = np.linalg.inv(W)
        P_mint = np.linalg.solve(S.T @ Wi @ S, S.T @ Wi)

        # 2. Forecast 12 steps + quantiles for all 7 series
        res = {"step": list(range(1, 13)), "t5m_lambda": [lam] * 12}
        base_cols = []
        for s in sectors_all:
            vals = train[s].values.copy()
            f_out = fc.forecast(vals, prediction_length=12)
            med = f_out.median.cpu().numpy().squeeze()
            q_mat = f_out.quantiles.cpu().numpy().squeeze()
            tau = np.array(f_out.quantile_levels)
            act = test[s].values[:, np.newaxis]
            L = np.where(act >= q_mat, tau * (act - q_mat), (1.0 - tau) * (q_mat - act))
            K = (len(tau) - 1) / 2.0
            bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
            wis_val = float(np.mean(np.sum(L, axis=1) / (K + 0.5)))
            crps_val = float(np.mean(2.0 * (L @ np.diff(bounds))))
            res[f"t5m_{s}"] = med.tolist()
            res[f"wis_t5m_{s}"] = [wis_val] * 12
            res[f"crps_t5m_{s}"] = [crps_val] * 12
            base_cols.append(med)

        base_mat = np.stack(base_cols, axis=1)  # (12, 7)
        rec_mat = (S @ P_mint @ base_mat.T).T
        coh_err = float(np.max(np.abs(rec_mat[:, 0] - np.sum(rec_mat[:, 1:], axis=1))))
        res["mint_t5m_coherence_err"] = [coh_err] * 12
        for i, s in enumerate(sectors_all):
            res[f"mint_t5m_{s}"] = rec_mat[:, i].tolist()

        res_df = pd.DataFrame(res)
        res_df["t5m_bottom_up"] = (
            res_df["t5m_automotive"] + res_df["t5m_food_beverage"] + res_df["t5m_clothing"]
            + res_df["t5m_ecommerce"] + res_df["t5m_general_merchandise"] + res_df["t5m_other"]
        )
        retail_timestral_5m = res_df
EOF
      echo "    __node_result = retail_timestral_5m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  retail_timestral_209m = stdenv.mkDerivation {
    name = "retail_timestral_209m";
    buildInputs = [ tBin py-env retail_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_retail_raw_data = retail_raw_data;
    T_INPUT_retail_raw_data = "${retail_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_retail_raw_data=${retail_raw_data}
      export T_INPUT_retail_raw_data=${retail_raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_retail_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_retail_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_retail_raw_data = py_read_json(os.path.join(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_retail_raw_data = py_read_csv(os.path.join(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.py
      echo "retail_raw_data = __dep_retail_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        train = retail_raw_data.iloc[:-12].copy()
        test  = retail_raw_data.iloc[-12:].copy()
        for d in (train, test):
            d["other"] = d["total"] - (d["automotive"] + d["food_beverage"] + d["clothing"] + d["ecommerce"] + d["general_merchandise"])

        sectors_all = ["total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other"]
        fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

        # 1. Programmatic assertion: verify batch evaluation matches individual 1D calls up to float32 precision (rtol=1e-5, atol=0.1)
        mat_train = np.stack([train[s].values for s in sectors_all], axis=0)
        test_sample = mat_train[:, :120].copy()
        batch_pred = fc.forecast(test_sample, prediction_length=1).median.cpu().numpy().squeeze()
        indiv_pred = np.array([fc.forecast(test_sample[idx], prediction_length=1).median.cpu().numpy().squeeze() for idx in range(len(sectors_all))])
        max_diff = float(np.max(np.abs(batch_pred - indiv_pred)))
        assert np.allclose(batch_pred, indiv_pred, rtol=1e-5, atol=0.1), f"Batch vs 1D parity failed for Timestral-209M: max diff is {max_diff}"

        # Rolling 1-step backtest residuals on training set (48 origins: 120..167) for MinT-shrink W
        res_list = []
        for o in range(120, mat_train.shape[1]):
            p1 = fc.forecast(mat_train[:, :o].copy(), prediction_length=1).median.cpu().numpy().squeeze()
            res_list.append(mat_train[:, o] - p1)
        res_mat = np.stack(res_list, axis=0)  # (48, 7)

        # Correlation-standardized Schäfer-Strimmer shrinkage
        n = res_mat.shape[0]
        covm = (res_mat.T @ res_mat) / n
        tar = np.diag(np.diag(covm))
        sd = np.sqrt(np.diag(covm))
        corm = covm / np.outer(sd, sd)
        xs = res_mat / sd[np.newaxis, :]
        v = (1.0 / (n * (n - 1))) * ((xs ** 2).T @ (xs ** 2) - ((xs.T @ xs) ** 2) / n)
        np.fill_diagonal(v, 0.0)
        d_mat = (corm - np.eye(len(sectors_all))) ** 2
        lam = float(np.clip(np.sum(v) / np.sum(d_mat), 0.0, 1.0))
        W = lam * tar + (1.0 - lam) * covm
        S = np.vstack([np.ones((1, 6)), np.eye(6)])
        Wi = np.linalg.inv(W)
        P_mint = np.linalg.solve(S.T @ Wi @ S, S.T @ Wi)

        # 2. Forecast 12 steps + quantiles for all 7 series
        res = {"step": list(range(1, 13)), "t209m_lambda": [lam] * 12}
        base_cols = []
        for s in sectors_all:
            vals = train[s].values.copy()
            f_out = fc.forecast(vals, prediction_length=12)
            med = f_out.median.cpu().numpy().squeeze()
            q_mat = f_out.quantiles.cpu().numpy().squeeze()
            tau = np.array(f_out.quantile_levels)
            act = test[s].values[:, np.newaxis]
            L = np.where(act >= q_mat, tau * (act - q_mat), (1.0 - tau) * (q_mat - act))
            K = (len(tau) - 1) / 2.0
            bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
            wis_val = float(np.mean(np.sum(L, axis=1) / (K + 0.5)))
            crps_val = float(np.mean(2.0 * (L @ np.diff(bounds))))
            res[f"t209m_{s}"] = med.tolist()
            res[f"wis_t209m_{s}"] = [wis_val] * 12
            res[f"crps_t209m_{s}"] = [crps_val] * 12
            base_cols.append(med)

        base_mat = np.stack(base_cols, axis=1)  # (12, 7)
        rec_mat = (S @ P_mint @ base_mat.T).T
        coh_err = float(np.max(np.abs(rec_mat[:, 0] - np.sum(rec_mat[:, 1:], axis=1))))
        res["mint_t209m_coherence_err"] = [coh_err] * 12
        for i, s in enumerate(sectors_all):
            res[f"mint_t209m_{s}"] = rec_mat[:, i].tolist()

        res_df = pd.DataFrame(res)
        res_df["t209m_bottom_up"] = (
            res_df["t209m_automotive"] + res_df["t209m_food_beverage"] + res_df["t209m_clothing"]
            + res_df["t209m_ecommerce"] + res_df["t209m_general_merchandise"] + res_df["t209m_other"]
        )
        retail_timestral_209m = res_df
EOF
      echo "    __node_result = retail_timestral_209m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  retail_benchmark_metrics = stdenv.mkDerivation {
    name = "retail_benchmark_metrics";
    buildInputs = [ tBin r-env helpers retail_r_arima retail_raw_data retail_timestral_209m retail_timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_retail_r_arima = retail_r_arima;
    T_INPUT_retail_r_arima = "${retail_r_arima}/artifact";
    T_NODE_retail_raw_data = retail_raw_data;
    T_INPUT_retail_raw_data = "${retail_raw_data}/artifact";
    T_NODE_retail_timestral_209m = retail_timestral_209m;
    T_INPUT_retail_timestral_209m = "${retail_timestral_209m}/artifact";
    T_NODE_retail_timestral_5m = retail_timestral_5m;
    T_INPUT_retail_timestral_5m = "${retail_timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_retail_r_arima=${retail_r_arima}
      export T_INPUT_retail_r_arima=${retail_r_arima}/artifact
      export T_NODE_retail_raw_data=${retail_raw_data}
      export T_INPUT_retail_raw_data=${retail_raw_data}/artifact
      export T_NODE_retail_timestral_209m=${retail_timestral_209m}
      export T_INPUT_retail_timestral_209m=${retail_timestral_209m}/artifact
      export T_NODE_retail_timestral_5m=${retail_timestral_5m}
      export T_INPUT_retail_timestral_5m=${retail_timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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








      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_r_arima\", \"class\")) && readLines(file.path(\"$T_NODE_retail_r_arima\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_r_arima <- r_read_json(file.path(\"$T_NODE_retail_r_arima\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_r_arima <- r_read_csv(file.path(\"$T_NODE_retail_r_arima\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_retail_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_json(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_csv(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_retail_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_timestral_209m <- r_read_json(file.path(\"$T_NODE_retail_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_timestral_209m <- r_read_csv(file.path(\"$T_NODE_retail_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_retail_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_timestral_5m <- r_read_json(file.path(\"$T_NODE_retail_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_timestral_5m <- r_read_csv(file.path(\"$T_NODE_retail_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "retail_r_arima <- dep_retail_r_arima" >> node_script.R
      echo "retail_raw_data <- dep_retail_raw_data" >> node_script.R
      echo "retail_timestral_209m <- dep_retail_timestral_209m" >> node_script.R
      echo "retail_timestral_5m <- dep_retail_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(retail_raw_data, 12)
      actual$other = actual$total - (actual$automotive + actual$food_beverage + actual$clothing + actual$ecommerce + actual$general_merchandise)
      sectors_all = c("total", "automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other")
      rows <- list()
      for (s in sectors_all) {
        act     = actual[[s]]
        n_p     = retail_r_arima[[paste0("naive_", s)]]
        a_p     = retail_r_arima[[paste0("arima_", s)]]
        ma_p    = retail_r_arima[[paste0("mint_arima_", s)]]
        e_p     = retail_r_arima[[paste0("ets_", s)]]
        me_p    = retail_r_arima[[paste0("mint_ets_", s)]]
        t5_p    = retail_timestral_5m[[paste0("t5m_", s)]]
        mt5_p   = retail_timestral_5m[[paste0("mint_t5m_", s)]]
        t20_p   = retail_timestral_209m[[paste0("t209m_", s)]]
        mt20_p  = retail_timestral_209m[[paste0("mint_t209m_", s)]]
        rows[[s]] = data.frame(
          sector          = s,
          naive_rmse      = round(rmse(n_p, act), 1),
          arima_rmse      = round(rmse(a_p, act), 1),
          mint_arima_rmse = round(rmse(ma_p, act), 1),
          ets_rmse        = round(rmse(e_p, act), 1),
          mint_ets_rmse   = round(rmse(me_p, act), 1),
          t5m_rmse        = round(rmse(t5_p, act), 1),
          mint_t5m_rmse   = round(rmse(mt5_p, act), 1),
          t209m_rmse      = round(rmse(t20_p, act), 1),
          mint_t209m_rmse = round(rmse(mt20_p, act), 1),
          wis_arima       = round(retail_r_arima[[paste0("wis_arima_", s)]][1], 1),
          wis_ets         = round(retail_r_arima[[paste0("wis_ets_", s)]][1], 1),
          wis_t5m         = round(retail_timestral_5m[[paste0("wis_t5m_", s)]][1], 1),
          wis_t209m       = round(retail_timestral_209m[[paste0("wis_t209m_", s)]][1], 1)
        )
      }
      retail_benchmark_metrics = do.call(rbind, rows)
      rownames(retail_benchmark_metrics) <- NULL
      retail_benchmark_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  retail_coherence_metrics = stdenv.mkDerivation {
    name = "retail_coherence_metrics";
    buildInputs = [ tBin r-env helpers retail_r_arima retail_raw_data retail_timestral_209m retail_timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_retail_r_arima = retail_r_arima;
    T_INPUT_retail_r_arima = "${retail_r_arima}/artifact";
    T_NODE_retail_raw_data = retail_raw_data;
    T_INPUT_retail_raw_data = "${retail_raw_data}/artifact";
    T_NODE_retail_timestral_209m = retail_timestral_209m;
    T_INPUT_retail_timestral_209m = "${retail_timestral_209m}/artifact";
    T_NODE_retail_timestral_5m = retail_timestral_5m;
    T_INPUT_retail_timestral_5m = "${retail_timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_retail_r_arima=${retail_r_arima}
      export T_INPUT_retail_r_arima=${retail_r_arima}/artifact
      export T_NODE_retail_raw_data=${retail_raw_data}
      export T_INPUT_retail_raw_data=${retail_raw_data}/artifact
      export T_NODE_retail_timestral_209m=${retail_timestral_209m}
      export T_INPUT_retail_timestral_209m=${retail_timestral_209m}/artifact
      export T_NODE_retail_timestral_5m=${retail_timestral_5m}
      export T_INPUT_retail_timestral_5m=${retail_timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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








      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_r_arima\", \"class\")) && readLines(file.path(\"$T_NODE_retail_r_arima\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_r_arima <- r_read_json(file.path(\"$T_NODE_retail_r_arima\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_r_arima <- r_read_csv(file.path(\"$T_NODE_retail_r_arima\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_retail_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_json(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_raw_data <- r_read_csv(file.path(\"$T_NODE_retail_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_retail_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_timestral_209m <- r_read_json(file.path(\"$T_NODE_retail_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_timestral_209m <- r_read_csv(file.path(\"$T_NODE_retail_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_retail_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_retail_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_retail_timestral_5m <- r_read_json(file.path(\"$T_NODE_retail_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_retail_timestral_5m <- r_read_csv(file.path(\"$T_NODE_retail_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "retail_r_arima <- dep_retail_r_arima" >> node_script.R
      echo "retail_raw_data <- dep_retail_raw_data" >> node_script.R
      echo "retail_timestral_209m <- dep_retail_timestral_209m" >> node_script.R
      echo "retail_timestral_5m <- dep_retail_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(retail_raw_data, 12)
      actual$other = actual$total - (actual$automotive + actual$food_beverage + actual$clothing + actual$ecommerce + actual$general_merchandise)
      sectors_bottom = c("automotive", "food_beverage", "clothing", "ecommerce", "general_merchandise", "other")
      sectors_all    = c("total", sectors_bottom)
      bu_ari = rowSums(sapply(sectors_bottom, function(s) retail_r_arima[[paste0("arima_", s)]]))
      bu_ets = rowSums(sapply(sectors_bottom, function(s) retail_r_arima[[paste0("ets_", s)]]))
      bu_t5m = retail_timestral_5m$t5m_bottom_up
      bu_t20 = retail_timestral_209m$t209m_bottom_up
      coh_ari_base = max(abs(retail_r_arima$arima_total - bu_ari))
      coh_ets_base = max(abs(retail_r_arima$ets_total - bu_ets))
      coh_t5m_base = max(abs(retail_timestral_5m$t5m_total - bu_t5m))
      coh_t20_base = max(abs(retail_timestral_209m$t209m_total - bu_t20))
      coh_mint_ari = retail_r_arima$mint_arima_coherence_err[1]
      coh_mint_ets = retail_r_arima$mint_ets_coherence_err[1]
      coh_mint_t5m = retail_timestral_5m$mint_t5m_coherence_err[1]
      coh_mint_t20 = retail_timestral_209m$mint_t209m_coherence_err[1]
      mean_bot_rmse <- function(df, prefix) {
        mean(sapply(sectors_bottom, function(s) rmse(df[[paste0(prefix, s)]], actual[[s]])))
      }
      retail_coherence_metrics = data.frame(
        method = c(
          "R ARIMA (Base non réconcilié)",
          "R ARIMA (Bottom-Up)",
          "R ARIMA (MinT-shrink)",
          "R ETS (Base non réconcilié)",
          "R ETS (Bottom-Up)",
          "R ETS (MinT-shrink)",
          "Timestral-5M (Base non réconcilié)",
          "Timestral-5M (Bottom-Up)",
          "Timestral-5M (MinT-shrink backtest)",
          "Timestral-209M (Base non réconcilié)",
          "Timestral-209M (Bottom-Up)",
          "Timestral-209M (MinT-shrink backtest)"
        ),
        is_reconciled = c(0L, 1L, 1L, 0L, 1L, 1L, 0L, 1L, 1L, 0L, 1L, 1L),
        shrinkage_lambda = round(c(
          0.0, 0.0, retail_r_arima$arima_lambda[1],
          0.0, 0.0, retail_r_arima$ets_lambda[1],
          0.0, 0.0, retail_timestral_5m$t5m_lambda[1],
          0.0, 0.0, retail_timestral_209m$t209m_lambda[1]
        ), 4),
        total_rmse = round(c(
          rmse(retail_r_arima$arima_total, actual$total),
          rmse(bu_ari, actual$total),
          rmse(retail_r_arima$mint_arima_total, actual$total),
          rmse(retail_r_arima$ets_total, actual$total),
          rmse(bu_ets, actual$total),
          rmse(retail_r_arima$mint_ets_total, actual$total),
          rmse(retail_timestral_5m$t5m_total, actual$total),
          rmse(bu_t5m, actual$total),
          rmse(retail_timestral_5m$mint_t5m_total, actual$total),
          rmse(retail_timestral_209m$t209m_total, actual$total),
          rmse(bu_t20, actual$total),
          rmse(retail_timestral_209m$mint_t209m_total, actual$total)
        ), 1),
        mean_bottom6_rmse = round(c(
          mean_bot_rmse(retail_r_arima, "arima_"),
          mean_bot_rmse(retail_r_arima, "arima_"),
          mean_bot_rmse(retail_r_arima, "mint_arima_"),
          mean_bot_rmse(retail_r_arima, "ets_"),
          mean_bot_rmse(retail_r_arima, "ets_"),
          mean_bot_rmse(retail_r_arima, "mint_ets_"),
          mean_bot_rmse(retail_timestral_5m, "t5m_"),
          mean_bot_rmse(retail_timestral_5m, "t5m_"),
          mean_bot_rmse(retail_timestral_5m, "mint_t5m_"),
          mean_bot_rmse(retail_timestral_209m, "t209m_"),
          mean_bot_rmse(retail_timestral_209m, "t209m_"),
          mean_bot_rmse(retail_timestral_209m, "mint_t209m_")
        ), 1),
        max_abs_incoherence = c(
          coh_ari_base, 0.0, coh_mint_ari,
          coh_ets_base, 0.0, coh_mint_ets,
          coh_t5m_base, 0.0, coh_mint_t5m,
          coh_t20_base, 0.0, coh_mint_t20
        ),
        max_abs_incoherence_sci = formatC(c(
          coh_ari_base, 0.0, coh_mint_ari,
          coh_ets_base, 0.0, coh_mint_ets,
          coh_t5m_base, 0.0, coh_mint_t5m,
          coh_t20_base, 0.0, coh_mint_t20
        ), format = "e", digits = 2)
      )
      retail_coherence_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  macro_raw_data = stdenv.mkDerivation {
    name = "macro_raw_data";
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
      __node_result = read_csv("data/macro_triad.csv", separator = ",")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_csv(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  macro_r_models = stdenv.mkDerivation {
    name = "macro_r_models";
    buildInputs = [ tBin r-env helpers macro_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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







      cat <<'EOF' >> node_script.R
library(forecast)
library(vars)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_macro_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_json(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_csv(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "macro_raw_data <- dep_macro_raw_data" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      train = head(macro_raw_data, -12)
      test  = tail(macro_raw_data, 12)
      naive_cpi      = rep(tail(train$cpi, 1), 12)
      q_naive_cpi    = forecast_quantiles("naive", h = 12, y_train = train$cpi)
      naive_unrate   = rep(tail(train$unrate, 1), 12)
      q_naive_unrate = forecast_quantiles("naive", h = 12, y_train = train$unrate)
      ts_cpi    = ts(train$cpi, frequency = 12)
      ts_unrate = ts(train$unrate, frequency = 12)
      fit_cpi_arima    = auto.arima(ts_cpi)
      fc_cpi_arima     = as.numeric(forecast(fit_cpi_arima, h = 12)$mean)
      q_cpi_arima      = forecast_quantiles(fit_cpi_arima, h = 12)
      cpi_arima_spec   = paste0("ARIMA(", paste(arimaorder(fit_cpi_arima), collapse = ","), ")")
      fit_cpi_ets      = ets(ts_cpi)
      fc_cpi_ets       = as.numeric(forecast(fit_cpi_ets, h = 12)$mean)
      q_cpi_ets        = forecast_quantiles(fit_cpi_ets, h = 12, npaths = 3000, seed = 2024)
      cpi_ets_spec     = fit_cpi_ets$method
      fit_unrate_arima  = auto.arima(ts_unrate)
      fc_unrate_arima   = as.numeric(forecast(fit_unrate_arima, h = 12)$mean)
      q_unrate_arima    = forecast_quantiles(fit_unrate_arima, h = 12)
      unrate_arima_spec = paste0("ARIMA(", paste(arimaorder(fit_unrate_arima), collapse = ","), ")")
      fit_unrate_ets    = ets(ts_unrate)
      fc_unrate_ets     = as.numeric(forecast(fit_unrate_ets, h = 12)$mean)
      q_unrate_ets      = forecast_quantiles(fit_unrate_ets, h = 12, npaths = 3000, seed = 2024)
      unrate_ets_spec   = fit_unrate_ets$method
      ts_train = ts(train[, c("cpi", "unrate", "fedfunds")], frequency = 12)
      sel      = VARselect(ts_train, lag.max = 8, type = "both")
      opt_p    = as.integer(sel$selection["AIC(n)"])
      fit_var  = VAR(ts_train, p = opt_p, type = "both")
      pred_var = predict(fit_var, n.ahead = 12)$fcst
      fit_cpi_arimax    = auto.arima(ts_cpi, xreg = train$fedfunds)
      fc_cpi_arimax     = as.numeric(forecast(fit_cpi_arimax, xreg = test$fedfunds, h = 12)$mean)
      q_cpi_arimax      = forecast_quantiles(fit_cpi_arimax, h = 12, xreg = test$fedfunds)
      cpi_arimax_spec   = paste0("ARIMAX(", paste(arimaorder(fit_cpi_arimax), collapse = ","), ")")
      fit_unrate_arimax  = auto.arima(ts_unrate, xreg = train$fedfunds)
      fc_unrate_arimax   = as.numeric(forecast(fit_unrate_arimax, xreg = test$fedfunds, h = 12)$mean)
      q_unrate_arimax    = forecast_quantiles(fit_unrate_arimax, h = 12, xreg = test$fedfunds)
      unrate_arimax_spec = paste0("ARIMAX(", paste(arimaorder(fit_unrate_arimax), collapse = ","), ")")
      out = data.frame(
        step               = 1:12,
        naive_cpi          = naive_cpi,
        naive_unrate       = naive_unrate,
        arima_cpi          = fc_cpi_arima,
        ets_cpi            = fc_cpi_ets,
        arima_unrate       = fc_unrate_arima,
        ets_unrate         = fc_unrate_ets,
        var_cpi            = as.numeric(pred_var$cpi[, "fcst"]),
        var_unrate         = as.numeric(pred_var$unrate[, "fcst"]),
        arimax_cpi         = fc_cpi_arimax,
        arimax_unrate      = fc_unrate_arimax,
        var_lag            = rep(opt_p, 12),
        cpi_arima_spec     = rep(cpi_arima_spec, 12),
        cpi_ets_spec       = rep(cpi_ets_spec, 12),
        cpi_arimax_spec    = rep(cpi_arimax_spec, 12),
        unrate_arima_spec  = rep(unrate_arima_spec, 12),
        unrate_ets_spec    = rep(unrate_ets_spec, 12),
        unrate_arimax_spec = rep(unrate_arimax_spec, 12)
      )
      for (cn in colnames(q_cpi_arima)) {
        out[[paste0("cpi_nai_", cn)]]    = q_naive_cpi[, cn]
        out[[paste0("cpi_ari_", cn)]]    = q_cpi_arima[, cn]
        out[[paste0("cpi_ets_", cn)]]    = q_cpi_ets[, cn]
        out[[paste0("cpi_arx_", cn)]]    = q_cpi_arimax[, cn]
        out[[paste0("unr_nai_", cn)]]    = q_naive_unrate[, cn]
        out[[paste0("unr_ari_", cn)]]    = q_unrate_arima[, cn]
        out[[paste0("unr_ets_", cn)]]    = q_unrate_ets[, cn]
        out[[paste0("unr_arx_", cn)]]    = q_unrate_arimax[, cn]
      }
      macro_r_models = out
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  macro_timestral_5m = stdenv.mkDerivation {
    name = "macro_timestral_5m";
    buildInputs = [ tBin py-env macro_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_json(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_csv(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "macro_raw_data = __dep_macro_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        train = macro_raw_data.iloc[:-12]
        fc = TimestralForecaster.from_pretrained("models/Timestral-5M")

        ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :].copy()
        res_cpi_u = fc.forecast(train["cpi"].values.copy(), prediction_length=12)
        res_cpi_c = fc.forecast(train["cpi"].values.copy(), prediction_length=12, known_covariates=ff_known)
        res_unr_u = fc.forecast(train["unrate"].values.copy(), prediction_length=12)
        res_unr_c = fc.forecast(train["unrate"].values.copy(), prediction_length=12, known_covariates=ff_known)

        q_levels = list(res_cpi_u.quantile_levels)
        data = {
            "step": list(range(1, 13)),
            "t5m_cpi_univ": res_cpi_u.median.cpu().numpy().squeeze().tolist(),
            "t5m_cpi_cov": res_cpi_c.median.cpu().numpy().squeeze().tolist(),
            "t5m_unrate_univ": res_unr_u.median.cpu().numpy().squeeze().tolist(),
            "t5m_unrate_cov": res_unr_c.median.cpu().numpy().squeeze().tolist(),
        }
        for tag, r_obj in [("cpi_u", res_cpi_u), ("cpi_c", res_cpi_c), ("unr_u", res_unr_u), ("unr_c", res_unr_c)]:
            qm = r_obj.quantiles.cpu().numpy().squeeze()
            for i, lvl in enumerate(q_levels):
                data[f"{tag}_q_{int(round(lvl * 100)):02d}"] = qm[:, i].tolist()

        # Context-length ablation on the exact same CPI series & 2024 target window
        full_cpi = train["cpi"].values
        for L in [60, 120, 168, 240, 288]:
            r_ctx = fc.forecast(full_cpi[-L:].copy(), prediction_length=12)
            data[f"ctx_{L}_med"] = r_ctx.median.cpu().numpy().squeeze().tolist()

        macro_timestral_5m = pd.DataFrame(data)
EOF
      echo "    __node_result = macro_timestral_5m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  macro_timestral_209m = stdenv.mkDerivation {
    name = "macro_timestral_209m";
    buildInputs = [ tBin py-env macro_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_json(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_csv(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "macro_raw_data = __dep_macro_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        train = macro_raw_data.iloc[:-12]
        fc = TimestralForecaster.from_pretrained("models/Timestral-209M")

        ff_known = macro_raw_data["fedfunds"].values[np.newaxis, np.newaxis, :].copy()
        res_cpi_u = fc.forecast(train["cpi"].values.copy(), prediction_length=12)
        res_cpi_c = fc.forecast(train["cpi"].values.copy(), prediction_length=12, known_covariates=ff_known)
        res_unr_u = fc.forecast(train["unrate"].values.copy(), prediction_length=12)
        res_unr_c = fc.forecast(train["unrate"].values.copy(), prediction_length=12, known_covariates=ff_known)

        q_levels = list(res_cpi_u.quantile_levels)
        data = {
            "step": list(range(1, 13)),
            "t209m_cpi_univ": res_cpi_u.median.cpu().numpy().squeeze().tolist(),
            "t209m_cpi_cov": res_cpi_c.median.cpu().numpy().squeeze().tolist(),
            "t209m_unrate_univ": res_unr_u.median.cpu().numpy().squeeze().tolist(),
            "t209m_unrate_cov": res_unr_c.median.cpu().numpy().squeeze().tolist(),
        }
        for tag, r_obj in [("cpi_u", res_cpi_u), ("cpi_c", res_cpi_c), ("unr_u", res_unr_u), ("unr_c", res_unr_c)]:
            qm = r_obj.quantiles.cpu().numpy().squeeze()
            for i, lvl in enumerate(q_levels):
                data[f"{tag}_q_{int(round(lvl * 100)):02d}"] = qm[:, i].tolist()

        # Context-length ablation on the exact same CPI series & 2024 target window
        full_cpi = train["cpi"].values
        for L in [60, 120, 168, 240, 288]:
            r_ctx = fc.forecast(full_cpi[-L:].copy(), prediction_length=12)
            data[f"ctx_{L}_med"] = r_ctx.median.cpu().numpy().squeeze().tolist()

        macro_timestral_209m = pd.DataFrame(data)
EOF
      echo "    __node_result = macro_timestral_209m" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  macro_benchmark_metrics = stdenv.mkDerivation {
    name = "macro_benchmark_metrics";
    buildInputs = [ tBin r-env helpers macro_r_models macro_raw_data macro_timestral_209m macro_timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_macro_r_models = macro_r_models;
    T_INPUT_macro_r_models = "${macro_r_models}/artifact";
    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    T_NODE_macro_timestral_209m = macro_timestral_209m;
    T_INPUT_macro_timestral_209m = "${macro_timestral_209m}/artifact";
    T_NODE_macro_timestral_5m = macro_timestral_5m;
    T_INPUT_macro_timestral_5m = "${macro_timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_macro_r_models=${macro_r_models}
      export T_INPUT_macro_r_models=${macro_r_models}/artifact
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact
      export T_NODE_macro_timestral_209m=${macro_timestral_209m}
      export T_INPUT_macro_timestral_209m=${macro_timestral_209m}/artifact
      export T_NODE_macro_timestral_5m=${macro_timestral_5m}
      export T_INPUT_macro_timestral_5m=${macro_timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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








      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_r_models\", \"class\")) && readLines(file.path(\"$T_NODE_macro_r_models\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_r_models <- r_read_json(file.path(\"$T_NODE_macro_r_models\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_r_models <- r_read_csv(file.path(\"$T_NODE_macro_r_models\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_macro_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_json(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_csv(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_macro_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_timestral_209m <- r_read_json(file.path(\"$T_NODE_macro_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_timestral_209m <- r_read_csv(file.path(\"$T_NODE_macro_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_macro_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_timestral_5m <- r_read_json(file.path(\"$T_NODE_macro_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_timestral_5m <- r_read_csv(file.path(\"$T_NODE_macro_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "macro_r_models <- dep_macro_r_models" >> node_script.R
      echo "macro_raw_data <- dep_macro_raw_data" >> node_script.R
      echo "macro_timestral_209m <- dep_macro_timestral_209m" >> node_script.R
      echo "macro_timestral_5m <- dep_macro_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
eval(parse(text = paste(helpers$code, collapse = "\n")))
      actual = tail(macro_raw_data, 12)
      q_cols = q_names()
      get_q <- function(df, prefix) {
        m = as.matrix(df[, paste0(prefix, q_cols)])
        colnames(m) = q_cols
        m
      }
      var_p   = macro_r_models$var_lag[1]
      var_lbl = paste0("VAR(p=", var_p, ", AIC)")
      act_c = actual$cpi
      n_c   = rmse(macro_r_models$naive_cpi, act_c)
      q_nc  = get_q(macro_r_models, "cpi_nai_")
      sc_nc = summarise_scores(score_rows(act_c, q_nc), digits = 3)
      n_wis_c = sc_nc$wis[1]
      act_u = actual$unrate
      n_u   = rmse(macro_r_models$naive_unrate, act_u)
      q_nu  = get_q(macro_r_models, "unr_nai_")
      sc_nu = summarise_scores(score_rows(act_u, q_nu), digits = 3)
      n_wis_u = sc_nu$wis[1]
      build_row <- function(target_lbl, act, n_rmse, n_wis, regime_lbl, mod_lbl, spec_lbl, pred, qmat = NULL) {
        r_val = rmse(pred, act)
        if (is.null(qmat)) {
          sc = data.frame(scaled_wis = NA_real_, wis = NA_real_, crps = NA_real_, mean_pinball = NA_real_,
                          coverage_80 = NA_real_, coverage_90 = NA_real_, width_80 = NA_real_, width_90 = NA_real_, crossings = 0L)
        } else {
          sc_val = summarise_scores(score_rows(act, qmat), digits = 3)
          s_wis  = if (is.na(n_wis) || n_wis == 0) NA_real_ else round(sc_val$wis / n_wis, 3)
          sc     = cbind(data.frame(scaled_wis = s_wis), sc_val)
        }
        cbind(
          data.frame(
            target        = target_lbl,
            regime        = regime_lbl,
            model         = mod_lbl,
            specification = spec_lbl,
            rmse          = round(r_val, 3),
            relative_rmse = round(r_val / n_rmse, 3)
          ),
          sc
        )
      }
      rows = list(
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_cpi, q_nc),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$cpi_arima_spec[1]), macro_r_models$arima_cpi, get_q(macro_r_models, "cpi_ari_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$cpi_ets_spec[1]), macro_r_models$ets_cpi, get_q(macro_r_models, "cpi_ets_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_cpi, NULL),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_cpi_univ, get_q(macro_timestral_5m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_cpi_univ, get_q(macro_timestral_209m, "cpi_u_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$cpi_arimax_spec[1]), macro_r_models$arimax_cpi, get_q(macro_r_models, "cpi_arx_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_cpi_cov, get_q(macro_timestral_5m, "cpi_c_")),
        build_row("CPI (Inflation)", act_c, n_c, n_wis_c, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_cpi_cov, get_q(macro_timestral_209m, "cpi_c_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Naive (Dernière valeur)", "RW(0)", macro_r_models$naive_unrate, q_nu),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "R ARIMA", as.character(macro_r_models$unrate_arima_spec[1]), macro_r_models$arima_unrate, get_q(macro_r_models, "unr_ari_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "R ETS", as.character(macro_r_models$unrate_ets_spec[1]), macro_r_models$ets_unrate, get_q(macro_r_models, "unr_ets_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "VAR multivarié", var_lbl, macro_r_models$var_unrate, NULL),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Timestral-5M Univarié", "L=288, sans cov.", macro_timestral_5m$t5m_unrate_univ, get_q(macro_timestral_5m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Ex-ante Inconditionnel", "Timestral-209M Univarié", "L=288, sans cov.", macro_timestral_209m$t209m_unrate_univ, get_q(macro_timestral_209m, "unr_u_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "ARIMAX (avec FedFunds)", as.character(macro_r_models$unrate_arimax_spec[1]), macro_r_models$arimax_unrate, get_q(macro_r_models, "unr_arx_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "Timestral-5M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_5m$t5m_unrate_cov, get_q(macro_timestral_5m, "unr_c_")),
        build_row("UNRATE (Chômage)", act_u, n_u, n_wis_u, "Conditionnel (Oracle FedFunds)", "Timestral-209M (avec FedFunds)", "L=288 + known_covariates", macro_timestral_209m$t209m_unrate_cov, get_q(macro_timestral_209m, "unr_c_"))
      )
      macro_benchmark_metrics = do.call(rbind, rows)
      rownames(macro_benchmark_metrics) <- NULL
      macro_benchmark_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  rolling_timestral = stdenv.mkDerivation {
    name = "rolling_timestral";
    buildInputs = [ tBin py-env macro_raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact

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
import pandas as pd
import numpy as np
from timestral import TimestralForecaster
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")) and open(os.path.join(\"$T_NODE_macro_raw_data\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_json(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_macro_raw_data = py_read_csv(os.path.join(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.py
      echo "macro_raw_data = __dep_macro_raw_data" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        import numpy as np
        from timestral import TimestralForecaster

        N = len(macro_raw_data)  # 300
        all_dates = pd.date_range("2000-01-01", periods=300, freq="MS").strftime("%Y-%m").tolist()

        # 24 origins spaced every 6 months across 2012-2023 (ending at L=288, test 2024):
        # L in [150, 156, ..., 282, 288]
        origins = [288 - (23 - i) * 6 for i in range(24)]

        fc5   = TimestralForecaster.from_pretrained("models/Timestral-5M")
        fc209 = TimestralForecaster.from_pretrained("models/Timestral-209M")

        rows = []
        for v in ["cpi", "unrate"]:
            y = macro_raw_data[v].values
            for idx, L in enumerate(origins):
                ctx = y[:L].copy()
                act = y[L : L + 12]
                w_start = all_dates[L]
                w_end = all_dates[L + 11]
                for mname, fc in [("Timestral-5M", fc5), ("Timestral-209M", fc209)]:
                    out = fc.forecast(ctx, prediction_length=12)
                    med = out.median.cpu().numpy().squeeze()
                    q_mat = out.quantiles.cpu().numpy().squeeze()
                    tau = np.array(out.quantile_levels)
                    act_col = act[:, np.newaxis]
                    L_pin = np.where(act_col >= q_mat, tau * (act_col - q_mat), (1.0 - tau) * (q_mat - act_col))
                    K = (len(tau) - 1) / 2.0
                    bounds = np.concatenate([[0.0], 0.5 * (tau[:-1] + tau[1:]), [1.0]])
                    wis_vec = np.sum(L_pin, axis=1) / (K + 0.5)
                    crps_vec = 2.0 * (L_pin @ np.diff(bounds))
                    q_cols = [f"q_{int(round(lvl * 100)):02d}" for lvl in tau]
                    i10, i90 = q_cols.index("q_10"), q_cols.index("q_90")
                    i05, i95 = q_cols.index("q_05"), q_cols.index("q_95")
                    cov80 = float(np.mean((act >= q_mat[:, i10]) & (act <= q_mat[:, i90])))
                    cov90 = float(np.mean((act >= q_mat[:, i05]) & (act <= q_mat[:, i95])))
                    cross = int(np.sum(np.diff(q_mat, axis=1) < -1e-9))
                    rows.append({
                        "target": v,
                        "origin_idx": idx + 1,
                        "train_len": L,
                        "test_window": f"{w_start}..{w_end}",
                        "model": mname,
                        "err_h1": float(act[0] - med[0]),
                        "err_h12": float(act[11] - med[11]),
                        "rmse_12m": float(np.sqrt(np.mean((act - med) ** 2))),
                        "mae_12m": float(np.mean(np.abs(act - med))),
                        "wis_12m": float(np.mean(wis_vec)),
                        "crps_12m": float(np.mean(crps_vec)),
                        "cov80_12m": cov80,
                        "cov90_12m": cov90,
                        "crossings": cross,
                    })

        rolling_timestral = pd.DataFrame(rows)
EOF
      echo "    __node_result = rolling_timestral" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_csv(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  context_ablation_metrics = stdenv.mkDerivation {
    name = "context_ablation_metrics";
    buildInputs = [ tBin r-env helpers macro_raw_data macro_timestral_209m macro_timestral_5m ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    T_NODE_macro_timestral_209m = macro_timestral_209m;
    T_INPUT_macro_timestral_209m = "${macro_timestral_209m}/artifact";
    T_NODE_macro_timestral_5m = macro_timestral_5m;
    T_INPUT_macro_timestral_5m = "${macro_timestral_5m}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact
      export T_NODE_macro_timestral_209m=${macro_timestral_209m}
      export T_INPUT_macro_timestral_209m=${macro_timestral_209m}/artifact
      export T_NODE_macro_timestral_5m=${macro_timestral_5m}
      export T_INPUT_macro_timestral_5m=${macro_timestral_5m}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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







      cat <<'EOF' >> node_script.R
library(forecast)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_macro_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_json(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_csv(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_timestral_209m\", \"class\")) && readLines(file.path(\"$T_NODE_macro_timestral_209m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_timestral_209m <- r_read_json(file.path(\"$T_NODE_macro_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_timestral_209m <- r_read_csv(file.path(\"$T_NODE_macro_timestral_209m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_timestral_5m\", \"class\")) && readLines(file.path(\"$T_NODE_macro_timestral_5m\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_timestral_5m <- r_read_json(file.path(\"$T_NODE_macro_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_timestral_5m <- r_read_csv(file.path(\"$T_NODE_macro_timestral_5m\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "macro_raw_data <- dep_macro_raw_data" >> node_script.R
      echo "macro_timestral_209m <- dep_macro_timestral_209m" >> node_script.R
      echo "macro_timestral_5m <- dep_macro_timestral_5m" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      all_dates = format(seq(as.Date("2000-01-01"), by = "month", length.out = 300), "%Y-%m")
      train_cpi = head(macro_raw_data$cpi, 288)
      test_cpi  = tail(macro_raw_data$cpi, 12)
      L_grid    = c(60, 120, 168, 240, 288)
      ctx_rows = lapply(L_grid, function(L) {
        sub_y      = tail(train_cpi, L)
        start_date = all_dates[288 - L + 1]
        ts_sub     = ts(sub_y, frequency = 12)
        fit_a      = auto.arima(ts_sub)
        fc_a       = as.numeric(forecast(fit_a, h = 12)$mean)
        fit_e      = ets(ts_sub)
        fc_e       = as.numeric(forecast(fit_e, h = 12)$mean)
        p5         = macro_timestral_5m[[paste0("ctx_", L, "_med")]]
        p209       = macro_timestral_209m[[paste0("ctx_", L, "_med")]]
        data.frame(
          context_months = L,
          window_start   = start_date,
          arima_spec     = paste0("ARIMA(", paste(arimaorder(fit_a), collapse = ","), ")"),
          ets_spec       = fit_e$method,
          arima_rmse     = round(rmse(fc_a, test_cpi), 4),
          ets_rmse       = round(rmse(fc_e, test_cpi), 4),
          t5m_rmse       = round(rmse(p5, test_cpi), 4),
          t209m_rmse     = round(rmse(p209, test_cpi), 4)
        )
      })
      context_ablation_metrics = do.call(rbind, ctx_rows)
      rownames(context_ablation_metrics) <- NULL
      context_ablation_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  rolling_origin_metrics = stdenv.mkDerivation {
    name = "rolling_origin_metrics";
    buildInputs = [ tBin r-env helpers macro_raw_data rolling_timestral ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_helpers = helpers;
    T_INPUT_helpers = "${helpers}/artifact";
    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    T_NODE_rolling_timestral = rolling_timestral;
    T_INPUT_rolling_timestral = "${rolling_timestral}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_helpers=${helpers}
      export T_INPUT_helpers=${helpers}/artifact
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact
      export T_NODE_rolling_timestral=${rolling_timestral}
      export T_INPUT_rolling_timestral=${rolling_timestral}/artifact

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

r_save_meta <- function(object, path) {
  tryCatch({
    meta <- list()
    cls <- tryCatch(as.character(class(object)[1]), error = function(e) NULL)
    if (!is.null(cls) && length(cls) == 1 && !is.na(cls) && nzchar(cls)) meta$class <- cls
    if (is.data.frame(object)) {
      meta$kind <- "dataframe"
      meta$dimensions <- list(nrow(object), ncol(object))
      nms <- tryCatch(names(object), error = function(e) NULL)
      if (!is.null(nms)) meta$features <- as.list(as.character(nms))
    } else if (inherits(object, "table")) {
      meta$kind <- "table"
      dm <- tryCatch(dim(object), error = function(e) NULL)
      if (!is.null(dm) && length(dm) > 0 && !any(is.na(dm))) meta$dimensions <- as.list(as.integer(dm))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "pam")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      cl <- tryCatch(object$clustering, error = function(e) NULL)
      if (!is.null(cl) && length(cl) > 0) {
        meta$n_clusters <- length(unique(cl))
        meta$n_obs <- as.integer(length(cl))
      }
    } else if (!is.null(dim(object)) && length(dim(object)) == 2) {
      meta$kind <- "matrix"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (!is.null(dim(object)) && length(dim(object)) > 2) {
      meta$kind <- "array"
      meta$dimensions <- as.list(as.integer(dim(object)))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "factor")) {
      meta$kind <- "factor"
      lv <- tryCatch(levels(object), error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) {
        meta$n_levels <- length(lv)
        lv <- as.character(lv)
        if (length(lv) > 500) lv <- lv[1:500]
        meta$levels <- as.list(lv)
      }
    } else if (inherits(object, "ts")) {
      meta$kind <- "series"
      meta$n_obs <- as.integer(length(object))
      fr <- tryCatch(stats::frequency(object), error = function(e) NULL)
      metrics <- list()
      if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
      if (length(metrics) > 0) meta$metrics <- metrics
      st <- tryCatch(stats::start(object), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0 && !any(is.na(st))) meta$start <- paste(st, collapse = "-")
      en <- tryCatch(stats::end(object), error = function(e) NULL)
      if (!is.null(en) && length(en) > 0 && !any(is.na(en))) meta$end <- paste(en, collapse = "-")
    } else if (is.atomic(object) && is.null(dim(object)) && !inherits(object, "factor")) {
      meta$kind <- "vector"
      meta$dimensions <- list(length(object))
      tp <- tryCatch(typeof(object), error = function(e) NULL)
      if (inherits(object, "Date")) tp <- "date"
      else if (inherits(object, "POSIXt")) tp <- "datetime"
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$dtype <- tp
    } else if (inherits(object, "lm") || inherits(object, "glm")) {
      meta$kind <- "model"
      fam <- tryCatch(object$family$family, error = function(e) NULL)
      if (is.null(fam)) fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
      if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
        meta$task <- "classification"
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms) & nms != "(Intercept)"]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      s <- tryCatch(summary(object), error = function(e) NULL)
      if (!is.null(s)) {
        if (!is.null(s$r.squared) && length(s$r.squared) == 1 && !is.na(s$r.squared)) metrics$r_squared <- as.numeric(s$r.squared)
        if (!is.null(s$adj.r.squared) && length(s$adj.r.squared) == 1 && !is.na(s$adj.r.squared)) metrics$adj_r_squared <- as.numeric(s$adj.r.squared)
      }
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "randomForest")) {
      meta$kind <- "model"
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "classification") {
        meta$task <- "classification"
      } else if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && tp == "regression") {
        meta$task <- "regression"
      }
      nt <- tryCatch(object$ntree, error = function(e) NULL)
      if (!is.null(nt) && length(nt) == 1 && !is.na(nt)) meta$n_trees <- as.integer(nt)
      ny <- tryCatch(length(object$y), error = function(e) NULL)
      if (!is.null(ny) && length(ny) == 1 && !is.na(ny) && ny > 0) meta$n_obs <- as.integer(ny)
      tm <- tryCatch(attr(object$terms, "term.labels"), error = function(e) NULL)
      if (is.null(tm)) tm <- tryCatch(rownames(object$importance), error = function(e) NULL)
      if (!is.null(tm) && length(tm) > 0) {
        feats <- as.character(tm)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      metrics <- list()
      rsq <- tryCatch(object$rsq, error = function(e) NULL)
      if (!is.null(rsq) && length(rsq) >= 1 && !is.na(rsq[length(rsq)])) metrics$r_squared <- as.numeric(rsq[length(rsq)])
      er <- tryCatch(object$err.rate, error = function(e) NULL)
      if (!is.null(er) && nrow(er) >= 1 && "OOB" %in% colnames(er)) {
        oob <- tryCatch(er[nrow(er), "OOB"], error = function(e) NULL)
        if (!is.null(oob) && length(oob) == 1 && !is.na(oob)) metrics$oob_error <- as.numeric(oob)
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "xgb.Booster")) {
      meta$kind <- "model"
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      nr <- tryCatch(object$niter, error = function(e) NULL)
      if (is.null(nr)) nr <- tryCatch({
        dt <- xgboost::xgb.model.dt.tree(model = object)
        length(unique(dt$Tree))
      }, error = function(e) NULL)
      if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_rounds <- as.integer(nr)
    } else if (inherits(object, "lgb.Booster")) {
      meta$kind <- "model"
      pr <- tryCatch(object$params, error = function(e) NULL)
      if (!is.null(pr)) {
        objv <- tryCatch(pr$objective, error = function(e) NULL)
        if (!is.null(objv) && length(objv) == 1 && !is.na(objv)) {
          if (grepl("binary|multi", objv)) meta$task <- "classification"
          else if (grepl("regression|poisson|gamma|tweedie", objv)) meta$task <- "regression"
        }
        if (is.null(meta$n_rounds)) {
          ni <- tryCatch(pr$num_iterations, error = function(e) NULL)
          if (!is.null(ni) && length(ni) == 1 && !is.na(ni)) meta$n_rounds <- as.integer(ni)
        }
      }
      if (is.null(meta$n_rounds)) {
        bi <- tryCatch(object$best_iter, error = function(e) NULL)
        if (!is.null(bi) && length(bi) == 1 && !is.na(bi) && bi > 0) meta$n_rounds <- as.integer(bi)
      }
      fn <- tryCatch(object$feature_names, error = function(e) NULL)
      if (!is.null(fn) && length(fn) > 0) {
        feats <- as.character(fn)
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
    } else if (inherits(object, "kmeans")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      sz <- tryCatch(object$size, error = function(e) NULL)
      if (!is.null(sz) && length(sz) > 0) {
        meta$n_clusters <- length(sz)
        meta$n_obs <- as.integer(sum(sz))
      }
      ctr <- tryCatch(object$centers, error = function(e) NULL)
      if (!is.null(ctr)) {
        vn <- tryCatch(colnames(ctr), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      metrics <- list()
      bt <- tryCatch(as.numeric(object$betweenss), error = function(e) NULL)
      tt <- tryCatch(as.numeric(object$totss), error = function(e) NULL)
      if (!is.null(bt) && !is.null(tt) && length(bt) == 1 && length(tt) == 1 && !is.na(bt) && !is.na(tt) && tt != 0) {
        metrics$var_explained <- bt / tt
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "hclust") || inherits(object, "twins")) {
      meta$kind <- "model"
      meta$task <- "clustering"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      od <- tryCatch(object$order, error = function(e) NULL)
      if (!is.null(od) && length(od) > 0) meta$n_obs <- as.integer(length(od))
      ht <- tryCatch(object$height, error = function(e) NULL)
      if (!is.null(ht) && length(ht) > 0 && !any(is.na(ht))) {
        metrics <- list(max_height = as.numeric(max(ht)))
        meta$metrics <- metrics
      }
    } else if (inherits(object, "prcomp") || inherits(object, "princomp")) {
      meta$kind <- "model"
      meta$task <- "dim_reduction"
      sdv <- tryCatch(object$sdev, error = function(e) NULL)
      if (!is.null(sdv) && length(sdv) > 0 && !any(is.na(sdv))) {
        meta$n_components <- length(sdv)
        vv <- sdv^2
        if (sum(vv) != 0) meta$metrics <- list(var_first = as.numeric(vv[1] / sum(vv)))
      }
      rot <- tryCatch(object$rotation, error = function(e) NULL)
      if (is.null(rot)) rot <- tryCatch(object$loadings, error = function(e) NULL)
      if (!is.null(rot)) {
        vn <- tryCatch(rownames(rot), error = function(e) NULL)
        if (is.null(vn)) vn <- tryCatch(colnames(rot), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      xx <- tryCatch(object$x, error = function(e) NULL)
      if (!is.null(xx)) {
        nr <- tryCatch(nrow(xx), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      if (is.null(meta$n_obs)) {
        no <- tryCatch(object$n.obs, error = function(e) NULL)
        if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      }
    } else if (inherits(object, "HoltWinters")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      for (nm in c("alpha", "beta", "gamma")) {
        vv <- tryCatch(object[[nm]], error = function(e) NULL)
        if (is.numeric(vv) && length(vv) == 1 && !is.na(vv)) metrics[[nm]] <- as.numeric(vv)
      }
      sse <- tryCatch(as.numeric(object$SSE), error = function(e) NULL)
      if (!is.null(sse) && length(sse) == 1 && !is.na(sse)) metrics$sse <- sse
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$x), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "StructTS")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (is.null(ll)) ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
      no <- tryCatch(length(object$data), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "stl")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      tsm <- tryCatch(object$time.series, error = function(e) NULL)
      if (!is.null(tsm)) {
        nr <- tryCatch(nrow(tsm), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
        vn <- tryCatch(colnames(tsm), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
        fr <- tryCatch(stats::frequency(tsm), error = function(e) NULL)
        metrics <- list()
        if (!is.null(fr) && length(fr) == 1 && !is.na(fr) && fr > 0) metrics$period <- as.integer(fr)
        if (length(metrics) > 0) meta$metrics <- metrics
      }
    } else if (inherits(object, "coxph")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(as.integer(object$n), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- no
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(utils::tail(object$loglik, 1)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      ci <- tryCatch(as.numeric(object$concordance[["concordance"]]), error = function(e) NULL)
      if (!is.null(ci) && length(ci) == 1 && !is.na(ci)) metrics$concordance <- ci
      nev <- tryCatch(as.integer(object$nevent), error = function(e) NULL)
      if (!is.null(nev) && length(nev) == 1 && !is.na(nev)) metrics$n_events <- nev
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "survfit")) {
      meta$kind <- "model"
      meta$task <- "survival"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) > 0 && !any(is.na(no))) meta$n_obs <- as.integer(sum(no))
      st <- tryCatch(names(object$strata), error = function(e) NULL)
      if (!is.null(st) && length(st) > 0) {
        meta$n_groups <- length(st)
        if (length(st) <= 50) meta$groups <- as.list(setNames(as.integer(object$n), st))
      }
    } else if (inherits(object, "rpart")) {
      meta$kind <- "model"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md)) {
        if (md == "class") meta$task <- "classification"
        else meta$task <- "regression"
      }
      fr <- tryCatch(object$frame, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_nodes <- as.integer(nr)
        vv <- tryCatch(fr$var, error = function(e) NULL)
        if (!is.null(vv)) {
          feats <- unique(as.character(vv[vv != "<leaf>" & !is.na(vv)]))
          if (length(feats) > 0) {
            meta$n_features <- length(feats)
            meta$features <- as.list(feats)
          }
        }
      }
    } else if (inherits(object, "density")) {
      meta$kind <- "distribution"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      bw <- tryCatch(as.numeric(object$bw), error = function(e) NULL)
      if (!is.null(bw) && length(bw) == 1 && !is.na(bw)) metrics$bw <- bw
      kn <- tryCatch(object$kernel, error = function(e) NULL)
      if (!is.null(kn) && length(kn) == 1 && !is.na(kn) && nzchar(kn)) meta$method <- kn
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "acf")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(object$n.used, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      tp <- tryCatch(object$type, error = function(e) NULL)
      if (!is.null(tp) && length(tp) == 1 && !is.na(tp) && nzchar(tp)) meta$method <- tp
      se <- tryCatch(object$series, error = function(e) NULL)
      if (!is.null(se) && length(se) == 1 && !is.na(se) && nzchar(se)) meta$target <- se
    } else if (inherits(object, "smooth.spline")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      lam <- tryCatch(as.numeric(object$lambda), error = function(e) NULL)
      if (!is.null(lam) && length(lam) == 1 && !is.na(lam)) metrics$lambda <- lam
      df <- tryCatch(as.numeric(object$df), error = function(e) NULL)
      if (!is.null(df) && length(df) == 1 && !is.na(df)) metrics$df <- df
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "ecdf")) {
      meta$kind <- "distribution"
      no <- tryCatch(get("nobs", envir = environment(object)), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
    } else if (inherits(object, "merMod")) {
      meta$kind <- "model"
      if (inherits(object, "glmerMod")) {
        fam <- tryCatch(stats::family(object)$family, error = function(e) NULL)
        if (!is.null(fam) && length(fam) == 1 && !is.na(fam) && fam == "binomial") {
          meta$task <- "classification"
        } else {
          meta$task <- "regression"
        }
      } else {
        meta$task <- "regression"
      }
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(lme4::fixef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(feats)
      }
      ng <- tryCatch(lme4::ngrps(object), error = function(e) NULL)
      if (!is.null(ng) && length(ng) > 0 && !any(is.na(ng))) {
        meta$n_groups <- as.integer(sum(ng))
        gnm <- names(ng)
        if (is.null(gnm)) gnm <- paste0("group", seq_along(ng))
        meta$groups <- as.list(setNames(as.integer(ng), gnm))
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(stats::logLik(object)), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      dv <- tryCatch(as.numeric(stats::deviance(object)), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "lda") || inherits(object, "qda")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$N, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      mn <- tryCatch(object$means, error = function(e) NULL)
      if (!is.null(mn)) {
        vn <- tryCatch(colnames(mn), error = function(e) NULL)
        if (!is.null(vn) && length(vn) > 0) {
          meta$n_features <- length(vn)
          meta$features <- as.list(as.character(vn))
        }
      }
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "polr")) {
      meta$kind <- "model"
      meta$task <- "classification"
      no <- tryCatch(object$nobs, error = function(e) NULL)
      if (is.null(no)) no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(names(object$coefficients), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "fitdistr")) {
      meta$kind <- "model"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      es <- tryCatch(object$estimate, error = function(e) NULL)
      if (!is.null(es) && length(es) > 0) {
        nms <- names(es)
        if (!is.null(nms)) {
          meta$n_features <- length(nms)
          meta$features <- as.list(as.character(nms))
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nls")) {
      meta$kind <- "model"
      meta$task <- "regression"
      fm <- tryCatch(stats::formula(object), error = function(e) NULL)
      if (!is.null(fm)) {
        meta$formula <- paste(deparse(fm), collapse = " ")
        fch <- tryCatch(as.character(fm), error = function(e) NULL)
        if (!is.null(fch) && length(fch) == 3 && !is.na(fch[2]) && nzchar(fch[2])) meta$target <- fch[2]
      }
      cf <- tryCatch(names(stats::coef(object)), error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        meta$n_features <- length(cf)
        meta$features <- as.list(as.character(cf))
      }
      rs <- tryCatch(stats::residuals(object), error = function(e) NULL)
      if (!is.null(rs) && length(rs) > 0) meta$n_obs <- as.integer(length(rs))
      metrics <- list()
      sg <- tryCatch(as.numeric(stats::sigma(object)), error = function(e) NULL)
      if (!is.null(sg) && length(sg) == 1 && !is.na(sg)) metrics$sigma <- sg
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "htest")) {
      meta$kind <- "test"
      md <- tryCatch(object$method, error = function(e) NULL)
      if (!is.null(md) && length(md) == 1 && !is.na(md) && nzchar(md)) meta$method <- md
      metrics <- list()
      pv <- tryCatch(as.numeric(object$p.value), error = function(e) NULL)
      if (!is.null(pv) && length(pv) == 1 && !is.na(pv)) metrics$p_value <- pv
      st <- tryCatch(as.numeric(object$statistic), error = function(e) NULL)
      if (!is.null(st) && length(st) == 1 && !is.na(st)) metrics$statistic <- st
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "loess")) {
      meta$kind <- "model"
      meta$task <- "regression"
      no <- tryCatch(object$n, error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      metrics <- list()
      sp <- tryCatch(object$pars$span, error = function(e) NULL)
      if (!is.null(sp) && length(sp) == 1 && !is.na(sp)) metrics$span <- as.numeric(sp)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "multinom")) {
      meta$kind <- "model"
      meta$task <- "classification"
      metrics <- list()
      lv <- tryCatch(object$lev, error = function(e) NULL)
      if (!is.null(lv) && length(lv) > 0) metrics$n_classes <- length(lv)
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      dv <- tryCatch(as.numeric(object$deviance), error = function(e) NULL)
      if (!is.null(dv) && length(dv) == 1 && !is.na(dv)) metrics$deviance <- dv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "nnet")) {
      meta$kind <- "model"
      lv <- tryCatch(object$lev, error = function(e) NULL)
      metrics <- list()
      if (!is.null(lv) && length(lv) > 0) {
        meta$task <- "classification"
        metrics$n_classes <- length(lv)
      }
      fr <- tryCatch(object$fitted.values, error = function(e) NULL)
      if (!is.null(fr)) {
        nr <- tryCatch(nrow(fr), error = function(e) NULL)
        if (is.null(nr)) nr <- tryCatch(length(fr), error = function(e) NULL)
        if (!is.null(nr) && length(nr) == 1 && !is.na(nr)) meta$n_obs <- as.integer(nr)
      }
      cf <- tryCatch(object$coefnames, error = function(e) NULL)
      if (!is.null(cf) && length(cf) > 0) {
        feats <- cf[!is.na(cf) & cf != "(Intercept)"]
        meta$n_features <- length(feats)
        meta$features <- as.list(as.character(feats))
      }
      vv <- tryCatch(as.numeric(object$value), error = function(e) NULL)
      if (!is.null(vv) && length(vv) == 1 && !is.na(vv)) metrics$loss <- vv
      if (length(metrics) > 0) meta$metrics <- metrics
    } else if (inherits(object, "Arima") || inherits(object, "arima")) {
      meta$kind <- "model"
      meta$task <- "time_series"
      no <- tryCatch(stats::nobs(object), error = function(e) NULL)
      if (!is.null(no) && length(no) == 1 && !is.na(no)) meta$n_obs <- as.integer(no)
      arma <- tryCatch(object$arma, error = function(e) NULL)
      if (!is.null(arma) && length(arma) == 7 && !any(is.na(arma))) {
        arma <- as.integer(arma)
        meta$order <- list(arma[1], arma[6], arma[2])
        if (arma[5] > 1 && (arma[3] > 0 || arma[7] > 0 || arma[4] > 0)) meta$seasonal_order <- list(arma[3], arma[7], arma[4], arma[5])
      }
      cf <- tryCatch(stats::coef(object), error = function(e) NULL)
      if (!is.null(cf)) {
        nms <- names(cf)
        if (!is.null(nms)) {
          feats <- nms[!is.na(nms)]
          meta$n_features <- length(feats)
          meta$features <- as.list(feats)
        } else {
          meta$n_features <- length(cf)
        }
      }
      metrics <- list()
      ll <- tryCatch(as.numeric(object$loglik), error = function(e) NULL)
      if (!is.null(ll) && length(ll) == 1 && !is.na(ll)) metrics$loglik <- ll
      s2 <- tryCatch(as.numeric(object$sigma2), error = function(e) NULL)
      if (!is.null(s2) && length(s2) == 1 && !is.na(s2)) metrics$sigma2 <- s2
      aic <- tryCatch(stats::AIC(object), error = function(e) NULL)
      if (!is.null(aic) && length(aic) == 1 && !is.na(aic)) metrics$aic <- as.numeric(aic)
      bic <- tryCatch(stats::BIC(object), error = function(e) NULL)
      if (!is.null(bic) && length(bic) == 1 && !is.na(bic)) metrics$bic <- as.numeric(bic)
      if (length(metrics) > 0) meta$metrics <- metrics
    } else {
      meta$kind <- "other"
    }
    if (!is.null(meta$features) && length(meta$features) > 500) meta$features <- meta$features[1:500]
    meta_write_ok <- tryCatch({
      jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
      TRUE
    }, error = function(e) FALSE)
    if (!isTRUE(meta_write_ok)) {
      meta$metrics <- NULL
      meta$features <- NULL
      meta$formula <- NULL
      meta_write_ok2 <- tryCatch({
        jsonlite::write_json(meta, path, auto_unbox = TRUE, null = "null", digits = NA)
        TRUE
      }, error = function(e) FALSE)
      if (!isTRUE(meta_write_ok2)) {
        try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
      }
    }
  }, error = function(e) {
    try(jsonlite::write_json(list(kind = "unknown"), path, auto_unbox = TRUE), silent = TRUE)
  })
  invisible(NULL)
}

EOF
      cat << 'EOF' >> node_script.R

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
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







      cat <<'EOF' >> node_script.R
library(forecast)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_helpers\", \"class\")) && readLines(file.path(\"$T_NODE_helpers\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_helpers <- r_read_json(file.path(\"$T_NODE_helpers\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_macro_raw_data\", \"class\")) && readLines(file.path(\"$T_NODE_macro_raw_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_json(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_macro_raw_data <- r_read_csv(file.path(\"$T_NODE_macro_raw_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "if (file.exists(file.path(\"$T_NODE_rolling_timestral\", \"class\")) && readLines(file.path(\"$T_NODE_rolling_timestral\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_rolling_timestral <- r_read_json(file.path(\"$T_NODE_rolling_timestral\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_rolling_timestral <- r_read_csv(file.path(\"$T_NODE_rolling_timestral\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "helpers <- dep_helpers" >> node_script.R
      echo "macro_raw_data <- dep_macro_raw_data" >> node_script.R
      echo "rolling_timestral <- dep_rolling_timestral" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      eval(parse(text = paste(helpers$code, collapse = "\n")))
      all_dates = format(seq(as.Date("2000-01-01"), by = "month", length.out = length(macro_raw_data$cpi)), "%Y-%m")
      origins = seq(150, 288, by = 6) # 24 origins spaced by 6 months
      covid_origins = origins[sapply(origins, function(L) any(c("2020-03", "2020-04") %in% all_dates[(L + 1):(L + 12)]))]
      idx_nocov = which(!origins %in% covid_origins)
      roll_rows = list()
      for (v in c("cpi", "unrate")) {
        y = macro_raw_data[[v]]
        t_lbl = if (v == "cpi") "CPI (24 origines)" else "UNRATE (24 origines)"
        e1_n = e12_n = r12_n = m12_n = w12_n = crps12_n = c80_n = numeric(length(origins))
        e1_a = e12_a = r12_a = m12_a = w12_a = crps12_a = c80_a = numeric(length(origins))
        e1_e = e12_e = r12_e = m12_e = w12_e = crps12_e = c80_e = numeric(length(origins))
        for (i in seq_along(origins)) {
          L = origins[i]
          tr = ts(y[1:L], frequency = 12)
          act = y[(L + 1):(L + 12)]
          p_n = rep(y[L], 12)
          q_n = forecast_quantiles("naive", h = 12, y_train = y[1:L])
          sc_n = score_rows(act, q_n)
          e1_n[i] = act[1] - p_n[1]; e12_n[i] = act[12] - p_n[12]
          r12_n[i] = rmse(p_n, act); m12_n[i] = mae(p_n, act)
          w12_n[i] = mean(sc_n$wis); crps12_n[i] = mean(sc_n$crps); c80_n[i] = mean(sc_n$in80)
          fit_a = auto.arima(tr)
          p_a   = as.numeric(forecast(fit_a, h = 12)$mean)
          sc_a  = score_rows(act, forecast_quantiles(fit_a, h = 12))
          e1_a[i] = act[1] - p_a[1]; e12_a[i] = act[12] - p_a[12]
          r12_a[i] = rmse(p_a, act); m12_a[i] = mae(p_a, act)
          w12_a[i] = mean(sc_a$wis); crps12_a[i] = mean(sc_a$crps); c80_a[i] = mean(sc_a$in80)
          fit_e = ets(tr)
          p_e   = as.numeric(forecast(fit_e, h = 12)$mean)
          sc_e  = score_rows(act, forecast_quantiles(fit_e, h = 12, npaths = 1000, seed = 2024 + i))
          e1_e[i] = act[1] - p_e[1]; e12_e[i] = act[12] - p_e[12]
          r12_e[i] = rmse(p_e, act); m12_e[i] = mae(p_e, act)
          w12_e[i] = mean(sc_e$wis); crps12_e[i] = mean(sc_e$crps); c80_e[i] = mean(sc_e$in80)
        }
        sub_t5   = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-5M", ]
        sub_t209 = rolling_timestral[rolling_timestral$target == v & rolling_timestral$model == "Timestral-209M", ]
        sub_t5   = sub_t5[order(sub_t5$origin_idx), ]
        sub_t209 = sub_t209[order(sub_t209$origin_idx), ]
        dm_n_1    = dm_harvey(e1_n, e1_a, h = 1);             dm_n_12    = dm_harvey(e12_n, e12_a, h = 2)
        dm_e_1    = dm_harvey(e1_e, e1_a, h = 1);             dm_e_12    = dm_harvey(e12_e, e12_a, h = 2)
        dm_t5_1   = dm_harvey(sub_t5$err_h1, e1_a, h = 1);    dm_t5_12   = dm_harvey(sub_t5$err_h12, e12_a, h = 2)
        dm_t209_1 = dm_harvey(sub_t209$err_h1, e1_a, h = 1);  dm_t209_12 = dm_harvey(sub_t209$err_h12, e12_a, h = 2)
        models_vec = c("Naive (RW)", "R ARIMA (réf. DM)", "R ETS", "Timestral-5M", "Timestral-209M")
        df_h1 = data.frame(
          target        = t_lbl,
          horizon       = "Pas 1 (h=1)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(e1_n^2)), sqrt(mean(e1_a^2)), sqrt(mean(e1_e^2)), sqrt(mean(sub_t5$err_h1^2)), sqrt(mean(sub_t209$err_h1^2))), 3),
          mae           = round(c(mean(abs(e1_n)), mean(abs(e1_a)), mean(abs(e1_e)), mean(abs(sub_t5$err_h1)), mean(abs(sub_t209$err_h1))), 3),
          rmse_ex_covid = round(c(sqrt(mean(e1_n[idx_nocov]^2)), sqrt(mean(e1_a[idx_nocov]^2)), sqrt(mean(e1_e[idx_nocov]^2)), sqrt(mean(sub_t5$err_h1[idx_nocov]^2)), sqrt(mean(sub_t209$err_h1[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(abs(e1_n[idx_nocov])), mean(abs(e1_a[idx_nocov])), mean(abs(e1_e[idx_nocov])), mean(abs(sub_t5$err_h1[idx_nocov])), mean(abs(sub_t209$err_h1[idx_nocov]))), 3),
          wis           = NA_real_,
          crps          = NA_real_,
          coverage_80   = NA_real_,
          dm_stat       = unname(c(round(dm_n_1["stat"], 3), NA_real_, round(dm_e_1["stat"], 3), round(dm_t5_1["stat"], 3), round(dm_t209_1["stat"], 3))),
          dm_pval       = unname(c(round(dm_n_1["pval"], 4), NA_real_, round(dm_e_1["pval"], 4), round(dm_t5_1["pval"], 4), round(dm_t209_1["pval"], 4)))
        )
        df_h12 = data.frame(
          target        = t_lbl,
          horizon       = "Pas 12 (h=12)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(e12_n^2)), sqrt(mean(e12_a^2)), sqrt(mean(e12_e^2)), sqrt(mean(sub_t5$err_h12^2)), sqrt(mean(sub_t209$err_h12^2))), 3),
          mae           = round(c(mean(abs(e12_n)), mean(abs(e12_a)), mean(abs(e12_e)), mean(abs(sub_t5$err_h12)), mean(abs(sub_t209$err_h12))), 3),
          rmse_ex_covid = round(c(sqrt(mean(e12_n[idx_nocov]^2)), sqrt(mean(e12_a[idx_nocov]^2)), sqrt(mean(e12_e[idx_nocov]^2)), sqrt(mean(sub_t5$err_h12[idx_nocov]^2)), sqrt(mean(sub_t209$err_h12[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(abs(e12_n[idx_nocov])), mean(abs(e12_a[idx_nocov])), mean(abs(e12_e[idx_nocov])), mean(abs(sub_t5$err_h12[idx_nocov])), mean(abs(sub_t209$err_h12[idx_nocov]))), 3),
          wis           = NA_real_,
          crps          = NA_real_,
          coverage_80   = NA_real_,
          dm_stat       = unname(c(round(dm_n_12["stat"], 3), NA_real_, round(dm_e_12["stat"], 3), round(dm_t5_12["stat"], 3), round(dm_t209_12["stat"], 3))),
          dm_pval       = unname(c(round(dm_n_12["pval"], 4), NA_real_, round(dm_e_12["pval"], 4), round(dm_t5_12["pval"], 4), round(dm_t209_12["pval"], 4)))
        )
        df_traj = data.frame(
          target        = t_lbl,
          horizon       = "Trajectoire (1..12m)",
          model         = models_vec,
          rmse          = round(c(sqrt(mean(r12_n^2)), sqrt(mean(r12_a^2)), sqrt(mean(r12_e^2)), sqrt(mean(sub_t5$rmse_12m^2)), sqrt(mean(sub_t209$rmse_12m^2))), 3),
          mae           = round(c(mean(m12_n), mean(m12_a), mean(m12_e), mean(sub_t5$mae_12m), mean(sub_t209$mae_12m)), 3),
          rmse_ex_covid = round(c(sqrt(mean(r12_n[idx_nocov]^2)), sqrt(mean(r12_a[idx_nocov]^2)), sqrt(mean(r12_e[idx_nocov]^2)), sqrt(mean(sub_t5$rmse_12m[idx_nocov]^2)), sqrt(mean(sub_t209$rmse_12m[idx_nocov]^2))), 3),
          mae_ex_covid  = round(c(mean(m12_n[idx_nocov]), mean(m12_a[idx_nocov]), mean(m12_e[idx_nocov]), mean(sub_t5$mae_12m[idx_nocov]), mean(sub_t209$mae_12m[idx_nocov])), 3),
          wis           = round(c(mean(w12_n), mean(w12_a), mean(w12_e), mean(sub_t5$wis_12m), mean(sub_t209$wis_12m)), 3),
          crps          = round(c(mean(crps12_n), mean(crps12_a), mean(crps12_e), mean(sub_t5$crps_12m), mean(sub_t209$crps_12m)), 3),
          coverage_80   = round(c(mean(c80_n), mean(c80_a), mean(c80_e), mean(sub_t5$cov80_12m), mean(sub_t209$cov80_12m)), 3),
          dm_stat       = NA_real_,
          dm_pval       = NA_real_
        )
        roll_rows[[paste0(v, "_h1")]]   = df_h1
        roll_rows[[paste0(v, "_h12")]]  = df_h12
        roll_rows[[paste0(v, "_traj")]] = df_traj
      }
      rolling_origin_metrics = do.call(rbind, roll_rows)
      rownames(rolling_origin_metrics) <- NULL
      rolling_origin_metrics
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
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  report = stdenv.mkDerivation {
    name = "report";
    buildInputs = [ tBin r-env py-env macro_raw_data benchmark_metrics cpi_probabilistic_metrics retail_benchmark_metrics retail_coherence_metrics macro_benchmark_metrics context_ablation_metrics rolling_origin_metrics ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_macro_raw_data = macro_raw_data;
    T_INPUT_macro_raw_data = "${macro_raw_data}/artifact";
    T_NODE_benchmark_metrics = benchmark_metrics;
    T_INPUT_benchmark_metrics = "${benchmark_metrics}/artifact";
    T_NODE_cpi_probabilistic_metrics = cpi_probabilistic_metrics;
    T_INPUT_cpi_probabilistic_metrics = "${cpi_probabilistic_metrics}/artifact";
    T_NODE_retail_benchmark_metrics = retail_benchmark_metrics;
    T_INPUT_retail_benchmark_metrics = "${retail_benchmark_metrics}/artifact";
    T_NODE_retail_coherence_metrics = retail_coherence_metrics;
    T_INPUT_retail_coherence_metrics = "${retail_coherence_metrics}/artifact";
    T_NODE_macro_benchmark_metrics = macro_benchmark_metrics;
    T_INPUT_macro_benchmark_metrics = "${macro_benchmark_metrics}/artifact";
    T_NODE_context_ablation_metrics = context_ablation_metrics;
    T_INPUT_context_ablation_metrics = "${context_ablation_metrics}/artifact";
    T_NODE_rolling_origin_metrics = rolling_origin_metrics;
    T_INPUT_rolling_origin_metrics = "${rolling_origin_metrics}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_macro_raw_data=${macro_raw_data}
      export T_INPUT_macro_raw_data=${macro_raw_data}/artifact
      export T_NODE_benchmark_metrics=${benchmark_metrics}
      export T_INPUT_benchmark_metrics=${benchmark_metrics}/artifact
      export T_NODE_cpi_probabilistic_metrics=${cpi_probabilistic_metrics}
      export T_INPUT_cpi_probabilistic_metrics=${cpi_probabilistic_metrics}/artifact
      export T_NODE_retail_benchmark_metrics=${retail_benchmark_metrics}
      export T_INPUT_retail_benchmark_metrics=${retail_benchmark_metrics}/artifact
      export T_NODE_retail_coherence_metrics=${retail_coherence_metrics}
      export T_INPUT_retail_coherence_metrics=${retail_coherence_metrics}/artifact
      export T_NODE_macro_benchmark_metrics=${macro_benchmark_metrics}
      export T_INPUT_macro_benchmark_metrics=${macro_benchmark_metrics}/artifact
      export T_NODE_context_ablation_metrics=${context_ablation_metrics}
      export T_INPUT_context_ablation_metrics=${context_ablation_metrics}/artifact
      export T_NODE_rolling_origin_metrics=${rolling_origin_metrics}
      export T_INPUT_rolling_origin_metrics=${rolling_origin_metrics}/artifact

      cat << EOF > node_script.sh

EOF













      sed -i -e "s|read_node(\"macro_raw_data\")|'$T_NODE_macro_raw_data/artifact'|g" -e "s|read_node('macro_raw_data')|'$T_NODE_macro_raw_data/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"benchmark_metrics\")|'$T_NODE_benchmark_metrics/artifact'|g" -e "s|read_node('benchmark_metrics')|'$T_NODE_benchmark_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"cpi_probabilistic_metrics\")|'$T_NODE_cpi_probabilistic_metrics/artifact'|g" -e "s|read_node('cpi_probabilistic_metrics')|'$T_NODE_cpi_probabilistic_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"retail_benchmark_metrics\")|'$T_NODE_retail_benchmark_metrics/artifact'|g" -e "s|read_node('retail_benchmark_metrics')|'$T_NODE_retail_benchmark_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"retail_coherence_metrics\")|'$T_NODE_retail_coherence_metrics/artifact'|g" -e "s|read_node('retail_coherence_metrics')|'$T_NODE_retail_coherence_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"macro_benchmark_metrics\")|'$T_NODE_macro_benchmark_metrics/artifact'|g" -e "s|read_node('macro_benchmark_metrics')|'$T_NODE_macro_benchmark_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"context_ablation_metrics\")|'$T_NODE_context_ablation_metrics/artifact'|g" -e "s|read_node('context_ablation_metrics')|'$T_NODE_context_ablation_metrics/artifact'|g" 'src/report.qmd'
      sed -i -e "s|read_node(\"rolling_origin_metrics\")|'$T_NODE_rolling_origin_metrics/artifact'|g" -e "s|read_node('rolling_origin_metrics')|'$T_NODE_rolling_origin_metrics/artifact'|g" 'src/report.qmd'

      mkdir -p $out
      
      rm -rf .quarto-output
      export HOME=$TMPDIR
      export QUARTO_R=${r-env}/bin/R
      export QUARTO_PYTHON=${py-env}/bin/python
      
      # Provision the tlang extension
      mkdir -p _extensions/tlang
      cp -r ${tBin}/share/tlang/quarto/tlang/* _extensions/tlang/
      export TLANG_BIN=${tBin}/bin/t

      cli_args=()
      cli_args+=('render')
      cli_args+=('src/report.qmd')
      cli_args+=('--output-dir')
      cli_args+=('.quarto-output')
      quarto "''${cli_args[@]}"
      if [ -d .quarto-output ]; then
        cp -r .quarto-output $out/artifact
      elif [ -d "$(dirname "src/report.qmd")/.quarto-output" ]; then
        cp -r "$(dirname "src/report.qmd")/.quarto-output" $out/artifact
      else
        echo "ERROR: .quarto-output not found."
        find . -name ".quarto-output" -type d
        ls -R
        exit 1
      fi
      echo "QuartoOutput" > $out/class
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin helpers raw_data r_arima timestral_5m timestral_209m benchmark_metrics cpi_probabilistic_metrics retail_raw_data retail_r_arima retail_timestral_5m retail_timestral_209m retail_benchmark_metrics retail_coherence_metrics macro_raw_data macro_r_models macro_timestral_5m macro_timestral_209m macro_benchmark_metrics rolling_timestral context_ablation_metrics rolling_origin_metrics report projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${helpers} $out/helpers
      cp -r ${raw_data} $out/raw_data
      cp -r ${r_arima} $out/r_arima
      cp -r ${timestral_5m} $out/timestral_5m
      cp -r ${timestral_209m} $out/timestral_209m
      cp -r ${benchmark_metrics} $out/benchmark_metrics
      cp -r ${cpi_probabilistic_metrics} $out/cpi_probabilistic_metrics
      cp -r ${retail_raw_data} $out/retail_raw_data
      cp -r ${retail_r_arima} $out/retail_r_arima
      cp -r ${retail_timestral_5m} $out/retail_timestral_5m
      cp -r ${retail_timestral_209m} $out/retail_timestral_209m
      cp -r ${retail_benchmark_metrics} $out/retail_benchmark_metrics
      cp -r ${retail_coherence_metrics} $out/retail_coherence_metrics
      cp -r ${macro_raw_data} $out/macro_raw_data
      cp -r ${macro_r_models} $out/macro_r_models
      cp -r ${macro_timestral_5m} $out/macro_timestral_5m
      cp -r ${macro_timestral_209m} $out/macro_timestral_209m
      cp -r ${macro_benchmark_metrics} $out/macro_benchmark_metrics
      cp -r ${rolling_timestral} $out/rolling_timestral
      cp -r ${context_ablation_metrics} $out/context_ablation_metrics
      cp -r ${rolling_origin_metrics} $out/rolling_origin_metrics
      cp -r ${report} $out/report
    '';
  };
}

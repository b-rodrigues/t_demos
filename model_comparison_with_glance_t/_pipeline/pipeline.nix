
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
  
    rSerializerPackages = [ "XML" "arrow" "jsonlite" "r2pmml" ];
    pySerializerPackages = [ "numpy" "pandas" "pyarrow" "scikit-learn" "scipy" "sklearn2pmml" "statsmodels" ];
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
  juliaPackagesList = (juliaDeps.packages or []) ++ [ "DataFrames" "CSV" "StatsModels" "JSON" "JLD2" "JavaCall" ];

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

  df = stdenv.mkDerivation {
    name = "df";
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

r_write_ipc <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_ipc <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      cat <<'EOF' >> node_script.R
library(datasets)
EOF



      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      data(mtcars)
      mtcars
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
  r_write_ipc(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_r = stdenv.mkDerivation {
    name = "model_r";
    buildInputs = [ tBin r-env df ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_df = df;
    T_INPUT_df = "${df}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_df=${df}
      export T_INPUT_df=${df}/artifact

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

r_write_ipc <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_ipc <- function(path) {
  arrow::read_ipc_file(path)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_pmml <- function(object, path) {
  if (inherits(object, "glmnet")) {
    r2pmml::r2pmml(object, path, lambda.s = object$lambda[1])
  } else {
    r2pmml::r2pmml(object, path)
  }
  
  # Enrichment for lm/glm/glmnet models
  if (inherits(object, "lm") || inherits(object, "glmnet")) {
    doc <- tryCatch(XML::xmlParse(path), error = function(e) NULL)
    if (is.null(doc)) return(invisible(NULL))
    
    root <- XML::xmlRoot(doc)
    fmt <- function(x) sprintf("%.15g", x)
    
    if (inherits(object, "glmnet")) {
      # For glmnet, we pull the coefficients for the current lambda
      # Note: object$lambda[1] was used for export
      coef_m <- as.matrix(coef(object, s = object$lambda[1]))
      
      coef_list <- list()
      for (nm in rownames(coef_m)) {
        coef_list[[nm]] <- list(
          estimate = coef_m[nm, 1]
        )
      }
      
      reg_nodes <- XML::getNodeSet(doc, "//*[local-name()='RegressionModel' or local-name()='GeneralRegressionModel' or local-name()='MiningModel']")
      if (length(reg_nodes) > 0) {
        reg_node <- reg_nodes[[1]]
        glm_ext <- XML::newXMLNode("Extension",
          attrs = list(
            name  = "GLMStats",
            value = jsonlite::toJSON(list(
              family              = "Gaussian", # glmnet default for alpha=0 is Gaussian if not specified
              link                = "identity",
              coefficients        = coef_list
            ), auto_unbox = TRUE)
          )
        )
        XML::addChildren(reg_node, glm_ext)
        XML::saveXML(doc, file = path)
      }
      return(invisible(NULL))
    }

    s <- tryCatch(summary(object), error = function(e) NULL)
    if (is.null(s)) return(invisible(NULL))
    
    coef_m <- s$coefficients
    is_glm <- inherits(object, "glm")
    
    # Update NumericPredictors and RegressionTable (for Intercept)
    for (nm in rownames(coef_m)) {
      # Namespace-agnostic XPath
      xpath_np <- sprintf("//*[local-name()='NumericPredictor' and @name='%s']", nm)
      if (nm == "(Intercept)") {
         xpath_np <- "//*[local-name()='NumericPredictor' and @name='(Intercept)']"
      }
      
      nodes <- XML::getNodeSet(doc, xpath_np)
      for (nd in nodes) {
        XML::xmlAttrs(nd)[["stdError"]]   <- fmt(coef_m[nm, "Std. Error"])
        stat_name <- if (is_glm) "zStatistic" else "tStatistic"
        XML::xmlAttrs(nd)[[stat_name]]    <- fmt(coef_m[nm, 3])
        XML::xmlAttrs(nd)[["pValue"]]     <- fmt(coef_m[nm, 4])
      }
      
      if (nm == "(Intercept)") {
        xpath_rt <- "//*[local-name()='RegressionTable']"
        nodes_rt <- XML::getNodeSet(doc, xpath_rt)
        for (nd in nodes_rt) {
          XML::xmlAttrs(nd)[["stdError"]]   <- fmt(coef_m[nm, "Std. Error"])
          stat_name <- if (is_glm) "zStatistic" else "tStatistic"
          XML::xmlAttrs(nd)[[stat_name]]    <- fmt(coef_m[nm, 3])
          XML::xmlAttrs(nd)[["pValue"]]     <- fmt(coef_m[nm, 4])
        }
      }
    }
    
    # Model-level statistics
    reg_nodes <- XML::getNodeSet(doc, "//*[local-name()='RegressionModel' or local-name()='GeneralRegressionModel']")
    if (length(reg_nodes) > 0) {
      reg_node <- reg_nodes[[1]]
      
      if (is_glm) {
        # Prepare coefficient data as JSON for fallback
        coef_list <- list()
        for (nm in rownames(coef_m)) {
          coef_list[[nm]] <- list(
            estimate = coef_m[nm, 1],
            std_error = coef_m[nm, 2],
            statistic = coef_m[nm, 3],
            p_value = coef_m[nm, 4]
          )
        }

        # GLM Specific Stats (Extension)
        glm_ext <- XML::newXMLNode("Extension",
          attrs = list(
            name  = "GLMStats",
            value = jsonlite::toJSON(list(
              family              = family(object)$family,
              link                = family(object)$link,
              null_deviance       = fmt(s$null.deviance),
              null_deviance_df    = s$df.null,
              residual_deviance   = fmt(s$deviance),
              residual_deviance_df= s$df.residual,
              dispersion          = fmt(s$dispersion),
              aic                 = fmt(s$aic),
              log_likelihood      = fmt(as.numeric(logLik(object))),
              coefficients        = coef_list
            ), auto_unbox = TRUE)
          )
        )
        XML::addChildren(reg_node, glm_ext)
      } else {
        # LM Specific Stats (PredictiveModelQuality)
        fstat <- if (!is.null(s$fstatistic)) fmt(s$fstatistic[1]) else "NA"
        fpval <- if (!is.null(s$fstatistic)) {
          fmt(pf(s$fstatistic[1], s$fstatistic[2], s$fstatistic[3], lower.tail = FALSE))
        } else "NA"
        
        quality <- XML::newXMLNode("PredictiveModelQuality",
          attrs = list(
            r2 = fmt(s$r.squared),
            `adj-r2` = fmt(s$adj.r.squared),
            aic = fmt(AIC(object)),
            bic = fmt(BIC(object)),
            sigma = fmt(s$sigma),
            nobs = nobs(object),
            fStatistic = fstat,
            fPValue = fpval,
            logLik = fmt(as.numeric(logLik(object))),
            deviance = fmt(deviance(object)),
            dfResidual = df.residual(object)
          )
        )
        XML::addChildren(reg_node, quality)
      }
    }
    
    XML::saveXML(doc, file = path)
  }
}
r_read_pmml <- function(path) {
  path
}

EOF





      echo "if (file.exists(file.path(\"$T_NODE_df\", \"class\")) && readLines(file.path(\"$T_NODE_df\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_df <- r_read_json(file.path(\"$T_NODE_df\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_df <- r_read_ipc(file.path(\"$T_NODE_df\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "df <- dep_df" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
lm(mpg ~ hp + wt + qsec, data = df)
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
  r_write_pmml(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_py = stdenv.mkDerivation {
    name = "model_py";
    buildInputs = [ tBin py-env df ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_df = df;
    T_INPUT_df = "${df}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_df=${df}
      export T_INPUT_df=${df}/artifact

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

import pyarrow as pa
import pyarrow.ipc as ipc
import pandas as pd

def py_write_ipc(df, path):
    if hasattr(df, 'to_arrow'):
        table = df.to_arrow()
    elif isinstance(df, pd.DataFrame):
        table = pa.Table.from_pandas(df)
    else:
        table = df
    with pa.OSFile(path, 'wb') as f:
        with ipc.new_file(f, table.schema) as writer:
            writer.write_table(table)

def py_read_ipc(path):
    with pa.OSFile(path, 'rb') as f:
        return ipc.open_file(f).read_pandas()

EOF

      cat << 'EOF' >> node_script.py

import os
import subprocess
import tempfile
import pickle

def py_write_pmml(model, path):
    # Check if it's a statsmodels model
    is_sm = False
    try:
        import statsmodels.base.wrapper as sm_wrapper
        if isinstance(model, sm_wrapper.ResultsWrapper):
            is_sm = True
        else:
            # Fallback for different statsmodels versions or types
            kls = type(model).__name__
            if "ResultsWrapper" in kls or hasattr(model, 'save'):
                # Double check it's not a False positive (sklearn models don't have .save)
                if hasattr(model, 'model') and hasattr(model, 'params'):
                    is_sm = True
    except ImportError: pass

    if is_sm:
        return py_export_sm_model(model, path)

    # Otherwise assume sklearn
    try:
        from sklearn2pmml import sklearn2pmml
    except ImportError as exc:
        raise ImportError(
            "PMML export in Python requires the 'sklearn2pmml' package for sklearn models."
        ) from exc
    
    # Basic export
    sklearn2pmml(model, path)
    # sklearn-specific enrichment omitted for brevity here, should follow previous pattern if needed
    _enrich_sklearn_pmml(model, path)

def py_export_sm_model(results, path):
    _assert_supported(results)

    with tempfile.TemporaryDirectory() as tmp:
        pkl_path = os.path.join(tmp, "model.pkl")
        results.save(pkl_path, remove_data=False)

        jar_path = _resolve_jpmml_statsmodels_jar()

        subprocess.run(
            [
                "java", "-jar", jar_path,
                "--pkl-input",  pkl_path,
                "--pmml-output", path,
            ],
            check=True,
        )

    _enrich_sm_model_pmml(results, path)
    return path

def _assert_supported(results):
    import statsmodels.genmod.generalized_linear_model as glm_module

    supported_families = {"Binomial", "Gaussian", "Poisson"}
    supported_links    = {"identity", "log", "logit"}

    if hasattr(results, "family") and results.family is not None:
        family_name = type(results.family).__name__
        link_name   = type(results.family.link).__name__.lower()

        if family_name not in supported_families:
            raise ValueError(
                f"GLM family '{family_name}' is not supported on the Python path. "
                f"Train in R to use this family."
            )
        if link_name not in supported_links:
            raise ValueError(
                f"Link function '{link_name}' is not supported on the Python path. "
                f"Train in R to use this link."
            )

def _resolve_jpmml_statsmodels_jar():
    jar = os.environ.get("T_JPMML_STATSMODELS_JAR")
    if not jar or not os.path.exists(jar):
        raise RuntimeError(
            "JPMML-StatsModels JAR not found. "
            "Ensure the t-pmml-java derivation is present in your environment."
        )
    return jar

def _enrich_sklearn_pmml(model, path):
    from sklearn.linear_model import LinearRegression
    if isinstance(model, LinearRegression) and hasattr(model, 'feature_names_in_'):
        try:
            import xml.etree.ElementTree as ET
            tree = ET.parse(path)
            root = tree.getroot()
            reg_model = None
            for el in root.iter():
                if el.tag.endswith('RegressionModel'):
                    reg_model = el
                    break
            if reg_model is not None:
                tag = reg_model.tag
                ns_prefix = tag[:tag.rfind('}')+1] if '}' in tag else ""
                quality = ET.SubElement(reg_model, ns_prefix + 'PredictiveModelQuality')
                for attr in ['r2_', 'adj_r2_', 'aic_', 'bic_', 'sigma_', 'nobs_', 'f_statistic_', 'f_p_value_', 'log_lik_', 'deviance_', 'df_residual_']:
                    if hasattr(model, attr):
                        quality.set(attr.replace('_', "").replace('adjr2', 'adj-r2'), str(getattr(model, attr)))
                tree.write(path)
        except Exception: pass

def _enrich_sm_model_pmml(results, path):
    import json
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(path)
        root = tree.getroot()
        reg_model = None
        for el in root.iter():
            if el.tag.endswith('RegressionModel') or el.tag.endswith('GeneralRegressionModel'):
                reg_model = el
                break
        if reg_model is not None:
            tag = reg_model.tag
            ns_prefix = tag[:tag.rfind('}')+1] if '}' in tag else ""
            
            if hasattr(results, "family") and results.family is not None:
                fam = type(results.family).__name__
                lnk = type(results.family.link).__name__.lower()
            else:
                fam = "Gaussian"
                lnk = "identity"
            
            coef_list = {}
            for name, coef in results.params.items():
                c_dict = {"estimate": float(coef)}
                try: c_dict["std_error"] = float(results.bse[name])
                except Exception: pass
                try:
                    stat = results.tvalues[name] if hasattr(results, 'tvalues') else (results.zvalues[name] if hasattr(results, 'zvalues') else None)
                    if stat is not None: c_dict["statistic"] = float(stat)
                except Exception: pass
                try: c_dict["p_value"] = float(results.pvalues[name])
                except Exception: pass
                coef_list[name] = c_dict
                
            glm_stats = {
                "family": fam,
                "link": lnk,
                "coefficients": coef_list
            }
            if hasattr(results, 'null_deviance'): glm_stats["null_deviance"] = str(float(results.null_deviance))
            if hasattr(results, 'df_null'): glm_stats["null_deviance_df"] = int(results.df_null)
            if hasattr(results, 'deviance'): glm_stats["residual_deviance"] = str(float(results.deviance))
            if hasattr(results, 'df_resid'): glm_stats["residual_deviance_df"] = int(results.df_resid)
            if hasattr(results, 'scale'): glm_stats["dispersion"] = str(float(results.scale))
            if hasattr(results, 'aic'): glm_stats["aic"] = str(float(results.aic))
            if hasattr(results, 'llf'): glm_stats["log_likelihood"] = str(float(results.llf))
            
            glm_ext = ET.SubElement(reg_model, ns_prefix + 'Extension')
            glm_ext.set('name', 'GLMStats')
            glm_ext.set('value', json.dumps(glm_stats))
            
            for el in reg_model.iter():
                if el.tag.endswith('NumericPredictor'):
                    nm = el.get('name')
                    if nm and nm in results.params:
                        try: el.set('stdError', str(results.bse[nm]))
                        except Exception: pass
                        try: el.set('zStatistic', str(results.tvalues[nm]))
                        except Exception: pass
                        try: el.set('pValue', str(results.pvalues[nm]))
                        except Exception: pass
                elif el.tag.endswith('RegressionTable'):
                    if 'const' in results.params:
                        try: el.set('stdError', str(results.bse['const']))
                        except Exception: pass
                        try: el.set('zStatistic', str(results.tvalues['const']))
                        except Exception: pass
                        try: el.set('pValue', str(results.pvalues['const']))
                        except Exception: pass

            tree.write(path)
    except Exception:
        pass

def py_read_pmml(path):
    class JPMMLModel:
        def __init__(self, pmml_path):
            self.pmml_path = pmml_path
        
        def predict(self, df):
            import subprocess
            import tempfile
            import os
            import pandas as pd

            jar_path = os.environ.get("T_JPMML_EVALUATOR_JAR")
            if not jar_path or not os.path.exists(jar_path):
                raise RuntimeError("T_JPMML_EVALUATOR_JAR not found in environment.")

            with tempfile.TemporaryDirectory() as tmp:
                in_path = os.path.join(tmp, "input.csv")
                out_path = os.path.join(tmp, "output.csv")
                
                # Write input (CSV standardized bridge)
                df.to_csv(in_path, index=False)
                
                # Execute JPMML
                subprocess.run([
                    "java", "-jar", jar_path,
                    "--model", self.pmml_path,
                    "--input", in_path,
                    "--output", out_path
                ], check=True)
                
                # Read output
                return pd.read_csv(out_path)
    
    return JPMMLModel(path)

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
from sklearn.linear_model import LinearRegression
from sklearn2pmml import sklearn2pmml
from sklearn2pmml.pipeline import PMMLPipeline
EOF

      echo "if os.path.exists(os.path.join(\"$T_NODE_df\", \"class\")) and open(os.path.join(\"$T_NODE_df\", \"class\")).read().strip() == \"VError\":" >> node_script.py
      echo "    __dep_df = py_read_json(os.path.join(\"$T_NODE_df\", \"artifact\"))" >> node_script.py
      echo "else:" >> node_script.py
      echo "    __dep_df = py_read_ipc(os.path.join(\"$T_NODE_df\", \"artifact\"))" >> node_script.py
      echo "df = __dep_df" >> node_script.py

      echo "import warnings" >> node_script.py
      echo "try:" >> node_script.py
      echo "    with warnings.catch_warnings(record=True) as captured_warns:" >> node_script.py
      echo "        warnings.simplefilter('always')" >> node_script.py
      cat <<'EOF' >> node_script.py
        import pandas as pd
        from sklearn.linear_model import LinearRegression
        from sklearn2pmml import sklearn2pmml
        from sklearn2pmml.pipeline import PMMLPipeline

        X = df[[${"'"}hp${"'"}, ${"'"}wt${"'"}, ${"'"}qsec${"'"}]]
        y = df[${"'"}mpg${"'"}]
        model_py = PMMLPipeline([("regressor", LinearRegression())]).fit(X, y)
EOF
      echo "    __node_result = model_py" >> node_script.py
      echo "except Exception as e:" >> node_script.py
      echo "    py_write_error(traceback.format_exc(), \"$out/artifact\")" >> node_script.py
      echo "    sys.exit(0)" >> node_script.py
      echo "if py_is_error(__node_result):" >> node_script.py
      echo "    py_write_error(__node_result, os.path.join(os.environ['out'], 'artifact'))" >> node_script.py
      echo "else:" >> node_script.py
      cat <<'EOF' >> node_script.py
    py_write_pmml(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}artifact${"'"}))
    py_save_meta(__node_result, os.path.join(os.environ[${"'"}out${"'"}], ${"'"}meta${"'"}))
EOF
      echo "    with open(os.path.join(os.environ['out'], 'class'), 'w') as f: f.write(py_visual_class(__node_result))" >> node_script.py
      echo "    py_write_warnings(captured_warns, os.path.join(os.environ['out'], 'warnings'))" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };
 

  comparison = stdenv.mkDerivation {
    name = "comparison";
    buildInputs = [ tBin model_py model_r ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_py = model_py;
    T_INPUT_model_py = "${model_py}/artifact";
    T_NODE_model_r = model_r;
    T_INPUT_model_r = "${model_r}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_py=${model_py}
      export T_INPUT_model_py=${model_py}/artifact
      export T_NODE_model_r=${model_r}
      export T_INPUT_model_r=${model_r}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_py/class\") && (read_file(\"$T_NODE_model_py/class\") == \"VError\" || read_file(\"$T_NODE_model_py/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_py/class\") == \"Error\" || read_file(\"$T_NODE_model_py/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_py = deserialize(\"$T_NODE_model_py/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_py = t_read_pmml(\"$T_NODE_model_py/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_r/class\") && (read_file(\"$T_NODE_model_r/class\") == \"VError\" || read_file(\"$T_NODE_model_r/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_r/class\") == \"Error\" || read_file(\"$T_NODE_model_r/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_r = deserialize(\"$T_NODE_model_r/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_r = t_read_pmml(\"$T_NODE_model_r/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_r = __dep_model_r
EOF
      cat <<'EOF' >> node_script.t
model_py = __dep_model_py
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
-- fit_stats() automatically stacks statistics when given a list.
      -- Naming items in the list (Regression_R: ...) adds a ${"'"}model${"'"} column.
      fit_stats([
        Regression_R: model_r, 
        Regression_Py: model_py
      ])
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
    buildInputs = [ tBin df model_r model_py comparison projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${df} $out/df
      cp -r ${model_r} $out/model_r
      cp -r ${model_py} $out/model_py
      cp -r ${comparison} $out/comparison
    '';
  };
}

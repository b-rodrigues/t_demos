
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
    pySerializerPackages = [  ];
  rPackagesList = (toml.r-dependencies or {}).packages or [];
    rRenvPackagesList = [ "jsonlite" "VGAM" "extraDistr" "mvtnorm" "Rcpp" "knitr" "xfun" "yaml" "evaluate" "highr" ];
    rGitPkgSet = rec {
    datathin = projectPkgs.rPackages.buildRPackage {
      pname = "datathin";
      name = "datathin";
      src = builtins.fetchGit {
        url = "https://github.com/anna-neufeld/datathin";
        rev = "58eb154609365fa7301ea0fa397fbf04dd8c28ed";
      };
      propagatedBuildInputs = (with projectPkgs.rPackages; [ VGAM extraDistr knitr mvtnorm ]) ++ [] ++ [ projectPkgs.R projectPkgs.gettext ];
    };
  };
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

  a = stdenv.mkDerivation {
    name = "a";
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF








      cat <<'EOF' >> node_script.R
library(jsonlite)
library(datathin)
EOF



      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
      result = toJSON(list(
        pkgs_loaded = "jsonlite, datathin",
        n_rnorm = length(rnorm(10))
      ), auto_unbox = TRUE)
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
  r_write_json(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
  r_save_meta(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}meta${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
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

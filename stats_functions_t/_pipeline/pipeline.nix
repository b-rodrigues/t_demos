
{ system ? builtins.currentSystem }:
let
  # Pull exact pinned inputs from the project flake.
  # The flake.lock guarantees reproducibility.
  # Note: toString is required to convert the path to a string
  # that builtins.getFlake accepts.
  flake  = builtins.getFlake (toString ../.);
  pkgs   = if (builtins.hasAttr "legacyPackages" flake && builtins.hasAttr system flake.legacyPackages.${system}) 
           then flake.legacyPackages.${system} 
           else flake.inputs.nixpkgs.legacyPackages.${system};
  tBin   = let
             base = (flake.inputs.t-lang or flake).packages.${system}.default;
           in if builtins.pathExists ../dune-project then
             base.overrideAttrs (old: { src = sources; })
           else base;
  stdenv = pkgs.stdenv;

  # Filter out _pipeline/, .git/, and other non-source directories
  sources = builtins.filterSource
    (path: type:
      let baseName = builtins.baseNameOf path;
      in !(baseName == "_pipeline" || baseName == ".git" || baseName == ".direnv" || baseName == "_build"))
    ../.;

  toml = if builtins.pathExists ../tproject.toml then builtins.fromTOML (builtins.readFile ../tproject.toml) else {};
  
  rPackagesList = (toml.r-dependencies or {}).packages or [];
  r-env = pkgs.rWrapper.override {
    packages = (builtins.map (p: pkgs.rPackages.${p}) rPackagesList);
  };

  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = pyDeps.version or "python3";
  pyPackagesList = pyDeps.packages or [];
  py-env = pkgs.${pyVersion}.withPackages (ps: (builtins.map (p: ps.${p}) pyPackagesList));

  # Additional Tools & LaTeX
  additionalTools = (toml.additional-tools or {}).packages or [];
  latexPkgs = (toml.latex or {}).packages or [];
  
  latexCombined = if latexPkgs == [] then null 
                  else pkgs.texlive.combine (builtins.listToAttrs (builtins.map (name: { name = name; value = pkgs.texlive.${name}; }) (["scheme-small"] ++ latexPkgs)));
                  
  globalBuildInputs = (builtins.map (p: pkgs.${p}) additionalTools)
                      ++ (if latexCombined == null then [] else [ latexCombined ]);
in
rec {

  stats_data = stdenv.mkDerivation {
    name = "stats_data";
    buildInputs = [ tBin  ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t




      echo "      stats_data = {" >> node_script.t
      cat <<'EOF' >> node_script.t
to_dataframe([
                [id: 1, group: "A", category: "apple",  value: 1.2, value_with_na: 1.2, basis_x: 1.0, feature_a: 2.0, feature_b: 1.0, response: 7.50, actual: 0.9, predicted: 1.1, success: 0],
                [id: 2, group: "A", category: "apple",  value: 2.5, value_with_na: 2.5, basis_x: 2.0, feature_a: 3.8, feature_b: 1.6, response: 10.20, actual: 1.8, predicted: 1.7, success: 0],
                [id: 3, group: "B", category: "banana", value: 3.1, value_with_na: 3.1, basis_x: 3.0, feature_a: 4.1, feature_b: 2.1, response: 11.00, actual: 3.2, predicted: 3.0, success: 0],
                [id: 4, group: "B", category: "cherry", value: 4.8, value_with_na: na_float(), basis_x: 4.0, feature_a: 5.9, feature_b: 2.8, response: 13.90, actual: 4.1, predicted: 4.4, success: 1],
                [id: 5, group: "C", category: "cherry", value: 5.2, value_with_na: 5.2, basis_x: 5.0, feature_a: 6.4, feature_b: 1.4, response: 16.00, actual: 5.4, predicted: 5.0, success: 1],
                [id: 6, group: "C", category: "apple",  value: 6.4, value_with_na: 6.4, basis_x: 6.0, feature_a: 7.1, feature_b: 2.3, response: 18.20, actual: 6.8, predicted: 6.9, success: 1],
                [id: 7, group: "A", category: "banana", value: 7.1, value_with_na: 7.1, basis_x: 7.0, feature_a: 8.7, feature_b: 2.9, response: 20.00, actual: 7.5, predicted: 7.2, success: 1],
                [id: 8, group: "B", category: "banana", value: 8.3, value_with_na: 8.3, basis_x: 8.0, feature_a: 9.2, feature_b: 3.2, response: 21.90, actual: 8.6, predicted: 8.4, success: 1]
            ])
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(stats_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(stats_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  counts_t = stdenv.mkDerivation {
    name = "counts_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      counts_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
stats_data
                |> group_by($group)
                |> summarize(rows = n(), unique_categories = n_distinct($category))
                |> arrange($group)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(counts_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(counts_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  counts_r = stdenv.mkDerivation {
    name = "counts_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF





      cat <<'EOF' >> node_script.R
library(dplyr)
EOF

      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "counts_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
            stats_data %>%
                group_by(group) %>%
                summarize(rows = n(), unique_categories = n_distinct(category), .groups = "drop") %>%
                arrange(group)
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
       echo "if (r_is_error(counts_r)) {" >> node_script.R
       echo "  r_write_error(counts_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(counts_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(counts_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  descriptive_t = stdenv.mkDerivation {
    name = "descriptive_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      descriptive_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
round_scalar = \(x) {
                if (is_error(x)) { x } else if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            }
            round_values = \(xs) { xs }
            clean_values = pull(stats_data, $value)
            values_with_na = pull(stats_data, $value_with_na)
            basis_values = pull(stats_data, $basis_x)
            actuals = pull(stats_data, $actual)
            preds = pull(stats_data, $predicted)
            residuals_vec = actuals .- preds
            -- Workaround for na_rm arity issues in current runtime
            clean_from_na = get(values_with_na, filter_lens(\(x) !is_na(x)))
            [
                mean: round_scalar(mean(clean_from_na)),
                median: round_scalar(median(clean_from_na)),
                min: round_scalar(min(clean_from_na)),
                max: round_scalar(max(clean_from_na)),
                range: round_values(range(clean_from_na)),
                var: round_scalar(var(clean_from_na)),
                sd: round_scalar(sd(clean_from_na)),
                iqr: round_scalar(iqr(clean_from_na)),
                mad: round_scalar(mad(clean_values)),
                fivenum: round_values(fivenum(clean_values)),
                quantile: [
                    round_scalar(quantile(clean_from_na, 0.25)),
                    round_scalar(quantile(clean_from_na, 0.5)),
                    round_scalar(quantile(clean_from_na, 0.75))
                ],
                skewness: round_scalar(skewness(clean_values)),
                kurtosis: round_scalar(kurtosis(clean_values)),
                trimmed_mean: round_scalar(trimmed_mean(clean_from_na, 0.125)),
                winsorize: round_values(winsorize(clean_values, [0.2, 0.2])),
                cv: round_scalar(cv(clean_values)),
                normalize: round_values(normalize(clean_values)),
                standardize: round_values(standardize(clean_values)),
                scale: round_values(scale(clean_values)),
                huber_loss: round_values(huber_loss(residuals_vec, 1.0)),
                cor: round_scalar(cor(clean_values, basis_values)),
                cov: round_scalar(cov(clean_values, basis_values)),
                pnorm: round_scalar(pnorm(0.25)),
                pt: round_scalar(pt(1.1, 5)),
                pf: round_scalar(pf(1.2, 3, 6)),
                pchisq: round_scalar(pchisq(2.5, 4))
            ]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(descriptive_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(descriptive_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  descriptive_r = stdenv.mkDerivation {
    name = "descriptive_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "descriptive_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
round_scalar <- function(x) round(as.numeric(x), 8)
            round_values <- function(x) unname(round(as.numeric(x), 8))
            skewness_t <- function(x) {
                m <- mean(x)
                m2 <- mean((x - m)^2)
                if (m2 == 0) return(0)
                mean((x - m)^3) / (m2^(1.5))
            }
            kurtosis_t <- function(x) {
                m <- mean(x)
                m2 <- mean((x - m)^2)
                if (m2 == 0) return(-3)
                mean((x - m)^4) / (m2^2) - 3
            }
            winsorize_t <- function(x, limits = c(0.2, 0.2)) {
                qs <- as.numeric(quantile(x, probs = c(limits[1], 1 - limits[2]), names = FALSE, type = 7))
                pmin(pmax(x, qs[1]), qs[2])
            }
            normalize_t <- function(x) {
                rng <- range(x)
                (x - rng[1]) / (rng[2] - rng[1])
            }
            huber_t <- function(x, delta = 1.0) {
                ifelse(abs(x) <= delta, 0.5 * x^2, delta * (abs(x) - 0.5 * delta))
            }
            clean_values <- stats_data$value
            values_with_na <- stats_data$value_with_na
            basis_values <- stats_data$basis_x
            residuals_vec <- stats_data$actual - stats_data$predicted
            list(
                mean = round_scalar(mean(values_with_na, na.rm = TRUE)),
                median = round_scalar(median(values_with_na, na.rm = TRUE)),
                min = round_scalar(min(values_with_na, na.rm = TRUE)),
                max = round_scalar(max(values_with_na, na.rm = TRUE)),
                range = round_values(range(values_with_na, na.rm = TRUE)),
                var = round_scalar(var(values_with_na, na.rm = TRUE)),
                sd = round_scalar(sd(values_with_na, na.rm = TRUE)),
                iqr = round_scalar(IQR(values_with_na, na.rm = TRUE)),
                mad = round_scalar(mad(clean_values, constant = 1.4826)),
                fivenum = round_values(fivenum(clean_values)),
                quantile = round_values(quantile(values_with_na, probs = c(0.25, 0.5, 0.75), na.rm = TRUE, names = FALSE, type = 7)),
                skewness = round_scalar(skewness_t(clean_values)),
                kurtosis = round_scalar(kurtosis_t(clean_values)),
                trimmed_mean = round_scalar(mean(values_with_na, trim = 0.125, na.rm = TRUE)),
                winsorize = round_values(winsorize_t(clean_values)),
                cv = round_scalar(sd(clean_values) / mean(clean_values)),
                normalize = round_values(normalize_t(clean_values)),
                standardize = round_values(as.numeric(scale(clean_values))),
                scale = round_values(as.numeric(scale(clean_values))),
                huber_loss = round_values(huber_t(residuals_vec, 1.0)),
                cor = round_scalar(cor(clean_values, basis_values)),
                cov = round_scalar(cov(clean_values, basis_values)),
                pnorm = round_scalar(pnorm(0.25)),
                pt = round_scalar(pt(1.1, 5)),
                pf = round_scalar(pf(1.2, 3, 6)),
                pchisq = round_scalar(pchisq(2.5, 4))
            )
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
       echo "if (r_is_error(descriptive_r)) {" >> node_script.R
       echo "  r_write_error(descriptive_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_json(descriptive_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(descriptive_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  basis_t = stdenv.mkDerivation {
    name = "basis_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      basis_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
poly_cols = poly(pull(stats_data, $basis_x), 3, raw = true)
            basis_core = stats_data |> select($id, $basis_x)
            basis_df = eval(to_expr(mutate(basis_core, !!!poly_cols)))
            basis_df = basis_df
                |> mutate(
                    $bucket = to_string(cut($basis_x, [0.0, 3.0, 6.0, 9.0])),
                    $poly1 = round($poly1, digits = 8),
                    $poly2 = round($poly2, digits = 8),
                    $poly3 = round($poly3, digits = 8)
                )
                |> select($id, $bucket, $poly1, $poly2, $poly3)
            basis_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(basis_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(basis_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  basis_r = stdenv.mkDerivation {
    name = "basis_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "basis_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
p <- poly(stats_data$basis_x, 3, raw = TRUE)
            data.frame(
                id = stats_data$id,
                bucket = as.character(cut(stats_data$basis_x, breaks = c(0, 3, 6, 9))),
                poly1 = round(p[, 1], 8),
                poly2 = round(p[, 2], 8),
                poly3 = round(p[, 3], 8)
            )
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
       echo "if (r_is_error(basis_r)) {" >> node_script.R
       echo "  r_write_error(basis_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(basis_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(basis_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_summary_t = stdenv.mkDerivation {
    name = "model_summary_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_summary_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            summary(full)._tidy_df
                |> select($term, $estimate, $std_error, $statistic, $p_value)
                |> mutate(
                    $estimate = round_safe($estimate),
                    $std_error = round_safe($std_error),
                    $statistic = round_safe($statistic),
                    $p_value = round_safe($p_value)
                )
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_summary_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_summary_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_summary_r = stdenv.mkDerivation {
    name = "model_summary_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_summary_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            smry <- as.data.frame(summary(full)$coefficients)
            data.frame(
                term = rownames(smry),
                estimate = round(smry[, 1], 8),
                std_error = round(smry[, 2], 8),
                statistic = round(smry[, 3], 8),
                p_value = round(smry[, 4], 8),
                row.names = NULL
            )
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
       echo "if (r_is_error(model_summary_r)) {" >> node_script.R
       echo "  r_write_error(model_summary_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_summary_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_summary_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_coef_t = stdenv.mkDerivation {
    name = "model_coef_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_coef_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            coef_df = coef(full)
                |> mutate($estimate = round_safe($estimate))
            coef_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_coef_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_coef_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_coef_r = stdenv.mkDerivation {
    name = "model_coef_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_coef_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            vals <- coef(full)
            data.frame(term = names(vals), estimate = round(as.numeric(vals), 8), row.names = NULL)
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
       echo "if (r_is_error(model_coef_r)) {" >> node_script.R
       echo "  r_write_error(model_coef_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_coef_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_coef_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_conf_int_t = stdenv.mkDerivation {
    name = "model_conf_int_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_conf_int_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            conf_int_df = conf_int(full)
                |> mutate($lower = round_safe($lower), $upper = round_safe($upper))
            conf_int_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_conf_int_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_conf_int_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_conf_int_r = stdenv.mkDerivation {
    name = "model_conf_int_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_conf_int_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            ci <- confint(full)
            data.frame(
                term = rownames(ci),
                lower = round(ci[, 1], 8),
                upper = round(ci[, 2], 8),
                row.names = NULL
            )
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
       echo "if (r_is_error(model_conf_int_r)) {" >> node_script.R
       echo "  r_write_error(model_conf_int_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_conf_int_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_conf_int_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_predict_t = stdenv.mkDerivation {
    name = "model_predict_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_predict_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            preds = predict(stats_data, full)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [
                first: round_safe(get(preds, idx_lens(0))),
                last: round_safe(get(preds, idx_lens(length(preds) - 1))),
                total: round_safe(sum(preds))
            ]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(model_predict_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_predict_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_predict_r = stdenv.mkDerivation {
    name = "model_predict_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_predict_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            preds <- predict(full, newdata = stats_data)
            list(
                first = round(as.numeric(preds[[1]]), 8),
                last = round(as.numeric(preds[[length(preds)]]), 8),
                total = round(sum(preds), 8)
            )
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
       echo "if (r_is_error(model_predict_r)) {" >> node_script.R
       echo "  r_write_error(model_predict_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_json(model_predict_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_predict_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_residuals_t = stdenv.mkDerivation {
    name = "model_residuals_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_residuals_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            resid_df = residuals(stats_data, full)
                |> mutate(
                    $actual = round_safe($actual),
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid)
                )
            resid_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_residuals_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_residuals_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_residuals_r = stdenv.mkDerivation {
    name = "model_residuals_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_residuals_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            data.frame(
                actual = round(stats_data$response, 8),
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(residuals(full)), 8)
            )
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
       echo "if (r_is_error(model_residuals_r)) {" >> node_script.R
       echo "  r_write_error(model_residuals_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_residuals_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_residuals_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_augment_t = stdenv.mkDerivation {
    name = "model_augment_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_augment_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            augment_df = add_diagnostics(stats_data, full)
                |> select($id, $fitted, $resid, $std_resid)
                |> mutate(
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid),
                    $std_resid = round_safe($std_resid)
                )
            augment_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_augment_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_augment_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_augment_r = stdenv.mkDerivation {
    name = "model_augment_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_augment_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            res <- residuals(full)
            data.frame(
                id = stats_data$id,
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(res), 8),
                std_resid = round(as.numeric(res / sigma(full)), 8)
            )
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
       echo "if (r_is_error(model_augment_r)) {" >> node_script.R
       echo "  r_write_error(model_augment_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_augment_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_augment_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_diagnostics_t = stdenv.mkDerivation {
    name = "model_diagnostics_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_diagnostics_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            diag_df = add_diagnostics(stats_data, full)
                |> select($id, $fitted, $resid, $hat, $sigma, $cooksd, $std_resid)
                |> mutate(
                    $fitted = round_safe($fitted),
                    $resid = round_safe($resid),
                    $hat = round_safe($hat),
                    $sigma = round_safe($sigma),
                    $cooksd = round_safe($cooksd),
                    $std_resid = round_safe($std_resid)
                )
            diag_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_diagnostics_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_diagnostics_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_diagnostics_r = stdenv.mkDerivation {
    name = "model_diagnostics_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_diagnostics_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            infl <- lm.influence(full)
            data.frame(
                id = stats_data$id,
                fitted = round(as.numeric(fitted(full)), 8),
                resid = round(as.numeric(residuals(full)), 8),
                hat = round(as.numeric(hatvalues(full)), 8),
                sigma = round(as.numeric(infl$sigma), 8),
                cooksd = round(as.numeric(cooks.distance(full)), 8),
                std_resid = round(as.numeric(rstandard(full)), 8)
            )
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
       echo "if (r_is_error(model_diagnostics_r)) {" >> node_script.R
       echo "  r_write_error(model_diagnostics_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_diagnostics_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_diagnostics_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_fit_stats_t = stdenv.mkDerivation {
    name = "model_fit_stats_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_fit_stats_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            md_full = full._model_data
            md_red = reduced._model_data
            fit_stats_df = to_dataframe([
                [model: "reduced", r_squared: md_red.r_squared, adj_r_squared: md_red.adj_r_squared, sigma: md_red.sigma, AIC: na_float(), BIC: na_float(), df_residual: md_red.df_residual, nobs: md_red.nobs],
                [model: "full",    r_squared: md_full.r_squared, adj_r_squared: md_full.adj_r_squared, sigma: md_full.sigma, AIC: na_float(), BIC: na_float(), df_residual: md_full.df_residual, nobs: md_full.nobs]
            ])
                |> mutate(
                    $r_squared = round_safe($r_squared),
                    $adj_r_squared = round_safe($adj_r_squared),
                    $sigma = round_safe($sigma),
                    $AIC = round_safe($AIC),
                    $BIC = round_safe($BIC),
                    $df_residual = round_safe($df_residual),
                    $nobs = round_safe($nobs)
                )
            fit_stats_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_fit_stats_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_fit_stats_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_fit_stats_r = stdenv.mkDerivation {
    name = "model_fit_stats_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_fit_stats_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            make_row <- function(name, fit) {
                smry <- summary(fit)
                data.frame(
                    model = name,
                    r_squared = round(smry$r.squared, 8),
                    adj_r_squared = round(smry$adj.r.squared, 8),
                    sigma = round(smry$sigma, 8),
                    AIC = round(AIC(fit), 8),
                    BIC = round(BIC(fit), 8),
                    df_residual = round(as.numeric(df.residual(fit)), 8),
                    nobs = round(as.numeric(nobs(fit)), 8)
                )
            }
            rbind(make_row("reduced", reduced), make_row("full", full))
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
       echo "if (r_is_error(model_fit_stats_r)) {" >> node_script.R
       echo "  r_write_error(model_fit_stats_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_fit_stats_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_fit_stats_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_compare_t = stdenv.mkDerivation {
    name = "model_compare_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_compare_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            compare_df = compare(reduced, full)
                |> select($term, $estimate_1, $estimate_2, $std_error_1, $std_error_2)
                |> mutate(
                    $estimate_1 = round_safe($estimate_1),
                    $estimate_2 = round_safe($estimate_2),
                    $std_error_1 = round_safe($std_error_1),
                    $std_error_2 = round_safe($std_error_2)
                )
            compare_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_compare_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_compare_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_compare_r = stdenv.mkDerivation {
    name = "model_compare_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_compare_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            reduced_smry <- as.data.frame(summary(reduced)$coefficients)
            full_smry <- as.data.frame(summary(full)$coefficients)
            reduced_smry$term <- rownames(reduced_smry)
            full_smry$term <- rownames(full_smry)
            terms <- unique(c(reduced_smry$term, full_smry$term))
            out <- data.frame(term = terms, stringsAsFactors = FALSE)
            out$estimate_1 <- round(reduced_smry[match(terms, reduced_smry$term), 1], 8)
            out$estimate_2 <- round(full_smry[match(terms, full_smry$term), 1], 8)
            out$std_error_1 <- round(reduced_smry[match(terms, reduced_smry$term), 2], 8)
            out$std_error_2 <- round(full_smry[match(terms, full_smry$term), 2], 8)
            out
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
       echo "if (r_is_error(model_compare_r)) {" >> node_script.R
       echo "  r_write_error(model_compare_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_compare_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_compare_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_score_t = stdenv.mkDerivation {
    name = "model_score_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_score_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            score_df = score(stats_data, full)
                |> mutate($rmse = round($rmse, digits = 8), $mae = round($mae, digits = 8), $r2 = round($r2, digits = 8))
            score_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_score_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_score_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_score_r = stdenv.mkDerivation {
    name = "model_score_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_score_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            preds <- predict(full, newdata = stats_data)
            resid <- stats_data$response - preds
            rmse <- sqrt(mean(resid^2))
            mae <- mean(abs(resid))
            r2 <- 1 - sum(resid^2) / sum((stats_data$response - mean(stats_data$response))^2)
            data.frame(rmse = round(rmse, 8), mae = round(mae, 8), r2 = round(r2, 8))
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
       echo "if (r_is_error(model_score_r)) {" >> node_script.R
       echo "  r_write_error(model_score_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_score_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_score_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_anova_t = stdenv.mkDerivation {
    name = "model_anova_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_anova_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = stats_data, formula = response ~ feature_a + feature_b)
            full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            round_with_na = \(x) { if (is_error(x)) { x } else if (is_na(x)) { na_float() } else { round(x, digits = 8) } }
            anova(reduced, full)
            -- Use internal data access to bypass missing standalone deviance/df_residual builtins in Nix env
            dr_red = reduced._model_data.df_residual
            dr_full = full._model_data.df_residual
            dev_red = reduced._model_data.deviance
            dev_full = full._model_data.deviance
            delta_df = dr_red - dr_full
            delta_dev = dev_red - dev_full
            f_stat = (delta_dev / delta_df) / (dev_full / dr_full)
            p_val = 1 - pf(f_stat, delta_df, dr_full)
            [
                [
                    df_residual: round_with_na(dr_red),
                    deviance: round_with_na(dev_red),
                    delta_df: na_float(),
                    delta_deviance: na_float(),
                    statistic: na_float(),
                    p_value: na_float()
                ],
                [
                    df_residual: round_with_na(dr_full),
                    deviance: round_with_na(dev_full),
                    delta_df: round_with_na(delta_df),
                    delta_deviance: round_with_na(delta_dev),
                    statistic: round_with_na(f_stat),
                    p_value: round_with_na(p_val)
                ]
            ]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(model_anova_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_anova_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_anova_r = stdenv.mkDerivation {
    name = "model_anova_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_anova_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
reduced <- lm(response ~ feature_a + feature_b, data = stats_data)
            full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            rows <- list(
                list(
                    df_residual = round(as.numeric(df.residual(reduced)), 8),
                    deviance = round(as.numeric(deviance(reduced)), 8),
                    delta_df = NA_real_,
                    delta_deviance = NA_real_,
                    statistic = NA_real_,
                    p_value = NA_real_
                )
            )
            delta_df <- df.residual(reduced) - df.residual(full)
            delta_dev <- deviance(reduced) - deviance(full)
            f_stat <- (delta_dev / delta_df) / (deviance(full) / df.residual(full))
            p_val <- 1 - pf(f_stat, delta_df, df.residual(full))
            rows[[2]] <- list(
                df_residual = round(as.numeric(df.residual(full)), 8),
                deviance = round(as.numeric(deviance(full)), 8),
                delta_df = round(as.numeric(delta_df), 8),
                delta_deviance = round(as.numeric(delta_dev), 8),
                statistic = round(as.numeric(f_stat), 8),
                p_value = round(as.numeric(p_val), 8)
            )
            rows
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
       echo "if (r_is_error(model_anova_r)) {" >> node_script.R
       echo "  r_write_error(model_anova_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_json(model_anova_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_anova_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_wald_t = stdenv.mkDerivation {
    name = "model_wald_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_wald_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            wald_df = wald_test(full, terms = ["feature_b", "basis_x"])
                |> select($terms, $statistic, $df, $p_value, $test_type)
                |> mutate(
                    $statistic = round($statistic, digits = 8),
                    $df = round($df, digits = 8),
                    $p_value = round($p_value, digits = 8)
                )
            wald_df
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_wald_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_wald_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_wald_r = stdenv.mkDerivation {
    name = "model_wald_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_wald_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            terms <- c("feature_b", "basis_x")
            beta <- coef(full)[terms]
            vc <- vcov(full)[terms, terms, drop = FALSE]
            q <- length(terms)
            w_stat <- as.numeric(t(beta) %*% solve(vc, beta))
            f_stat <- w_stat / q
            p_val <- 1 - pf(f_stat, q, df.residual(full))
            data.frame(
                terms = paste(terms, collapse = ", "),
                statistic = round(f_stat, 8),
                df = round(as.numeric(q), 8),
                p_value = round(p_val, 8),
                test_type = "F"
            )
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
       echo "if (r_is_error(model_wald_r)) {" >> node_script.R
       echo "  r_write_error(model_wald_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(model_wald_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_wald_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_scalars_t = stdenv.mkDerivation {
    name = "model_scalars_t";
    buildInputs = [ tBin stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      model_scalars_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
full = lm(data = stats_data, formula = response ~ feature_a + feature_b + basis_x)
            vc = vcov(full)
            round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [
                nobs: full._model_data.nobs,
                df_residual: full._model_data.df_residual,
                sigma: round_safe(full._model_data.sigma)
            ]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(model_scalars_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_scalars_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_scalars_r = stdenv.mkDerivation {
    name = "model_scalars_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_scalars_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
full <- lm(response ~ feature_a + feature_b + basis_x, data = stats_data)
            vc <- vcov(full)
            list(
                nobs = as.integer(nobs(full)),
                df_residual = as.integer(df.residual(full)),
                sigma = round(sigma(full), 8)
            )
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
       echo "if (r_is_error(model_scalars_r)) {" >> node_script.R
       echo "  r_write_error(model_scalars_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_json(model_scalars_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_scalars_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  glm_model_r = stdenv.mkDerivation {
    name = "glm_model_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
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





      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "glm_model_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
stats_data$success <- to_factor(stats_data$success, levels = c(0, 1), labels = c("No", "Yes"))
            glm(success ~ feature_a + feature_b, data = stats_data, family = binomial(link = "logit"))
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
       echo "if (r_is_error(glm_model_r)) {" >> node_script.R
       echo "  r_write_error(glm_model_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_pmml(glm_model_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(glm_model_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  model_dispersion_t = stdenv.mkDerivation {
    name = "model_dispersion_t";
    buildInputs = [ tBin glm_model_r ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_glm_model_r = glm_model_r;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_glm_model_r=${glm_model_r}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "glm_model_r = t_read_pmml(\"$T_NODE_glm_model_r/artifact\")" >> node_script.t

      echo "      model_dispersion_t = {" >> node_script.t
      cat <<'EOF' >> node_script.t
round_safe = \(x) if (is_na(x)) { na_float() } else { round(x, digits = 8) }
            [dispersion: round_safe(dispersion(glm_model_r))]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(model_dispersion_t, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_dispersion_t))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_dispersion_r = stdenv.mkDerivation {
    name = "model_dispersion_r";
    buildInputs = [ tBin r-env stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_stats_data=${stats_data}

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
    jsonlite::write_json(as.character(warns), path, auto_unbox = TRUE)
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF

      cat << 'EOF' >> node_script.R

r_write_arrow <- function(object, path) {
  arrow::write_ipc_file(as.data.frame(object), path)
}
r_read_arrow <- function(path) {
  arrow::read_ipc_file(path)
}

EOF






      echo "if (file.exists(file.path(\"$T_NODE_stats_data\", \"class\")) && readLines(file.path(\"$T_NODE_stats_data\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  stats_data <- r_read_json(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  stats_data <- r_read_arrow(file.path(\"$T_NODE_stats_data\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "model_dispersion_r <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
fit <- glm(success ~ feature_a + feature_b, data = stats_data, family = binomial(link = "logit"))
            list(dispersion = round(summary(fit)$dispersion, 8))
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
       echo "if (r_is_error(model_dispersion_r)) {" >> node_script.R
       echo "  r_write_error(model_dispersion_r, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_json(model_dispersion_r, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(model_dispersion_r), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  validation = stdenv.mkDerivation {
    name = "validation";
    buildInputs = [ tBin basis_r basis_t counts_r counts_t descriptive_r descriptive_t model_anova_r model_anova_t model_augment_r model_augment_t model_coef_r model_coef_t model_compare_r model_compare_t model_conf_int_r model_conf_int_t model_diagnostics_r model_diagnostics_t model_dispersion_r model_dispersion_t model_fit_stats_r model_fit_stats_t model_predict_r model_predict_t model_residuals_r model_residuals_t model_scalars_r model_scalars_t model_score_r model_score_t model_summary_r model_summary_t model_wald_r model_wald_t stats_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_basis_r = basis_r;
    T_NODE_basis_t = basis_t;
    T_NODE_counts_r = counts_r;
    T_NODE_counts_t = counts_t;
    T_NODE_descriptive_r = descriptive_r;
    T_NODE_descriptive_t = descriptive_t;
    T_NODE_model_anova_r = model_anova_r;
    T_NODE_model_anova_t = model_anova_t;
    T_NODE_model_augment_r = model_augment_r;
    T_NODE_model_augment_t = model_augment_t;
    T_NODE_model_coef_r = model_coef_r;
    T_NODE_model_coef_t = model_coef_t;
    T_NODE_model_compare_r = model_compare_r;
    T_NODE_model_compare_t = model_compare_t;
    T_NODE_model_conf_int_r = model_conf_int_r;
    T_NODE_model_conf_int_t = model_conf_int_t;
    T_NODE_model_diagnostics_r = model_diagnostics_r;
    T_NODE_model_diagnostics_t = model_diagnostics_t;
    T_NODE_model_dispersion_r = model_dispersion_r;
    T_NODE_model_dispersion_t = model_dispersion_t;
    T_NODE_model_fit_stats_r = model_fit_stats_r;
    T_NODE_model_fit_stats_t = model_fit_stats_t;
    T_NODE_model_predict_r = model_predict_r;
    T_NODE_model_predict_t = model_predict_t;
    T_NODE_model_residuals_r = model_residuals_r;
    T_NODE_model_residuals_t = model_residuals_t;
    T_NODE_model_scalars_r = model_scalars_r;
    T_NODE_model_scalars_t = model_scalars_t;
    T_NODE_model_score_r = model_score_r;
    T_NODE_model_score_t = model_score_t;
    T_NODE_model_summary_r = model_summary_r;
    T_NODE_model_summary_t = model_summary_t;
    T_NODE_model_wald_r = model_wald_r;
    T_NODE_model_wald_t = model_wald_t;
    T_NODE_stats_data = stats_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_basis_r=${basis_r}
      export T_NODE_basis_t=${basis_t}
      export T_NODE_counts_r=${counts_r}
      export T_NODE_counts_t=${counts_t}
      export T_NODE_descriptive_r=${descriptive_r}
      export T_NODE_descriptive_t=${descriptive_t}
      export T_NODE_model_anova_r=${model_anova_r}
      export T_NODE_model_anova_t=${model_anova_t}
      export T_NODE_model_augment_r=${model_augment_r}
      export T_NODE_model_augment_t=${model_augment_t}
      export T_NODE_model_coef_r=${model_coef_r}
      export T_NODE_model_coef_t=${model_coef_t}
      export T_NODE_model_compare_r=${model_compare_r}
      export T_NODE_model_compare_t=${model_compare_t}
      export T_NODE_model_conf_int_r=${model_conf_int_r}
      export T_NODE_model_conf_int_t=${model_conf_int_t}
      export T_NODE_model_diagnostics_r=${model_diagnostics_r}
      export T_NODE_model_diagnostics_t=${model_diagnostics_t}
      export T_NODE_model_dispersion_r=${model_dispersion_r}
      export T_NODE_model_dispersion_t=${model_dispersion_t}
      export T_NODE_model_fit_stats_r=${model_fit_stats_r}
      export T_NODE_model_fit_stats_t=${model_fit_stats_t}
      export T_NODE_model_predict_r=${model_predict_r}
      export T_NODE_model_predict_t=${model_predict_t}
      export T_NODE_model_residuals_r=${model_residuals_r}
      export T_NODE_model_residuals_t=${model_residuals_t}
      export T_NODE_model_scalars_r=${model_scalars_r}
      export T_NODE_model_scalars_t=${model_scalars_t}
      export T_NODE_model_score_r=${model_score_r}
      export T_NODE_model_score_t=${model_score_t}
      export T_NODE_model_summary_r=${model_summary_r}
      export T_NODE_model_summary_t=${model_summary_t}
      export T_NODE_model_wald_r=${model_wald_r}
      export T_NODE_model_wald_t=${model_wald_t}
      export T_NODE_stats_data=${stats_data}

      cat << EOF > node_script.t
EOF








      echo 'import base' >> node_script.t
      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "basis_r = read_arrow(\"$T_NODE_basis_r/artifact\")" >> node_script.t
      echo "basis_t = read_arrow(\"$T_NODE_basis_t/artifact\")" >> node_script.t
      echo "counts_r = read_arrow(\"$T_NODE_counts_r/artifact\")" >> node_script.t
      echo "counts_t = read_arrow(\"$T_NODE_counts_t/artifact\")" >> node_script.t
      echo "descriptive_r = t_read_json(\"$T_NODE_descriptive_r/artifact\")" >> node_script.t
      echo "descriptive_t = t_read_json(\"$T_NODE_descriptive_t/artifact\")" >> node_script.t
      echo "model_anova_r = t_read_json(\"$T_NODE_model_anova_r/artifact\")" >> node_script.t
      echo "model_anova_t = t_read_json(\"$T_NODE_model_anova_t/artifact\")" >> node_script.t
      echo "model_augment_r = read_arrow(\"$T_NODE_model_augment_r/artifact\")" >> node_script.t
      echo "model_augment_t = read_arrow(\"$T_NODE_model_augment_t/artifact\")" >> node_script.t
      echo "model_coef_r = read_arrow(\"$T_NODE_model_coef_r/artifact\")" >> node_script.t
      echo "model_coef_t = read_arrow(\"$T_NODE_model_coef_t/artifact\")" >> node_script.t
      echo "model_compare_r = read_arrow(\"$T_NODE_model_compare_r/artifact\")" >> node_script.t
      echo "model_compare_t = read_arrow(\"$T_NODE_model_compare_t/artifact\")" >> node_script.t
      echo "model_conf_int_r = read_arrow(\"$T_NODE_model_conf_int_r/artifact\")" >> node_script.t
      echo "model_conf_int_t = read_arrow(\"$T_NODE_model_conf_int_t/artifact\")" >> node_script.t
      echo "model_diagnostics_r = read_arrow(\"$T_NODE_model_diagnostics_r/artifact\")" >> node_script.t
      echo "model_diagnostics_t = read_arrow(\"$T_NODE_model_diagnostics_t/artifact\")" >> node_script.t
      echo "model_dispersion_r = t_read_json(\"$T_NODE_model_dispersion_r/artifact\")" >> node_script.t
      echo "model_dispersion_t = t_read_json(\"$T_NODE_model_dispersion_t/artifact\")" >> node_script.t
      echo "model_fit_stats_r = read_arrow(\"$T_NODE_model_fit_stats_r/artifact\")" >> node_script.t
      echo "model_fit_stats_t = read_arrow(\"$T_NODE_model_fit_stats_t/artifact\")" >> node_script.t
      echo "model_predict_r = t_read_json(\"$T_NODE_model_predict_r/artifact\")" >> node_script.t
      echo "model_predict_t = t_read_json(\"$T_NODE_model_predict_t/artifact\")" >> node_script.t
      echo "model_residuals_r = read_arrow(\"$T_NODE_model_residuals_r/artifact\")" >> node_script.t
      echo "model_residuals_t = read_arrow(\"$T_NODE_model_residuals_t/artifact\")" >> node_script.t
      echo "model_scalars_r = t_read_json(\"$T_NODE_model_scalars_r/artifact\")" >> node_script.t
      echo "model_scalars_t = t_read_json(\"$T_NODE_model_scalars_t/artifact\")" >> node_script.t
      echo "model_score_r = read_arrow(\"$T_NODE_model_score_r/artifact\")" >> node_script.t
      echo "model_score_t = read_arrow(\"$T_NODE_model_score_t/artifact\")" >> node_script.t
      echo "model_summary_r = read_arrow(\"$T_NODE_model_summary_r/artifact\")" >> node_script.t
      echo "model_summary_t = read_arrow(\"$T_NODE_model_summary_t/artifact\")" >> node_script.t
      echo "model_wald_r = read_arrow(\"$T_NODE_model_wald_r/artifact\")" >> node_script.t
      echo "model_wald_t = read_arrow(\"$T_NODE_model_wald_t/artifact\")" >> node_script.t
      echo "stats_data = read_arrow(\"$T_NODE_stats_data/artifact\")" >> node_script.t

      echo "      validation = {" >> node_script.t
      cat <<'EOF' >> node_script.t
assert(identical(counts_t, counts_r), "n()/n_distinct() results should match dplyr")
            assert(identical(descriptive_t, descriptive_r), "Descriptive stats results should match R")
            assert(identical(basis_t, basis_r), "cut()/poly() results should match R")
            assert(identical(model_summary_t, model_summary_r), "summary() results should match R")
            assert(identical(model_coef_t, model_coef_r), "coef() results should match R")
            assert(identical(model_conf_int_t, model_conf_int_r), "conf_int() results should match R")
            assert(identical(model_predict_t, model_predict_r), "predict() results should match R")
            assert(identical(model_residuals_t, model_residuals_r), "residuals() results should match R")
            assert(identical(model_augment_t, model_augment_r), "add_diagnostics() results should match R")
            assert(identical(model_diagnostics_t, model_diagnostics_r), "add_diagnostics() results should match R")
            assert(identical(model_fit_stats_t, model_fit_stats_r), "fit_stats() results should match R")
            assert(identical(model_compare_t, model_compare_r), "compare() results should match R")
            assert(identical(model_score_t, model_score_r), "score() results should match R")
            assert(identical(model_anova_t, model_anova_r), "anova() results should match R")
            assert(identical(model_wald_t, model_wald_r), "wald_test() results should match R")
            assert(identical(model_scalars_t, model_scalars_r), "nobs()/df_residual()/sigma()/vcov() results should match R")
            assert(identical(model_dispersion_t, model_dispersion_r), "dispersion() results should match R")
            [
                status: "ok",
                checked: 17,
                rows: nrow(stats_data)
            ]
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(validation, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(validation))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin stats_data counts_t counts_r descriptive_t descriptive_r basis_t basis_r model_summary_t model_summary_r model_coef_t model_coef_r model_conf_int_t model_conf_int_r model_predict_t model_predict_r model_residuals_t model_residuals_r model_augment_t model_augment_r model_diagnostics_t model_diagnostics_r model_fit_stats_t model_fit_stats_r model_compare_t model_compare_r model_score_t model_score_r model_anova_t model_anova_r model_wald_t model_wald_r model_scalars_t model_scalars_r glm_model_r model_dispersion_t model_dispersion_r validation ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${stats_data} $out/stats_data
      cp -r ${counts_t} $out/counts_t
      cp -r ${counts_r} $out/counts_r
      cp -r ${descriptive_t} $out/descriptive_t
      cp -r ${descriptive_r} $out/descriptive_r
      cp -r ${basis_t} $out/basis_t
      cp -r ${basis_r} $out/basis_r
      cp -r ${model_summary_t} $out/model_summary_t
      cp -r ${model_summary_r} $out/model_summary_r
      cp -r ${model_coef_t} $out/model_coef_t
      cp -r ${model_coef_r} $out/model_coef_r
      cp -r ${model_conf_int_t} $out/model_conf_int_t
      cp -r ${model_conf_int_r} $out/model_conf_int_r
      cp -r ${model_predict_t} $out/model_predict_t
      cp -r ${model_predict_r} $out/model_predict_r
      cp -r ${model_residuals_t} $out/model_residuals_t
      cp -r ${model_residuals_r} $out/model_residuals_r
      cp -r ${model_augment_t} $out/model_augment_t
      cp -r ${model_augment_r} $out/model_augment_r
      cp -r ${model_diagnostics_t} $out/model_diagnostics_t
      cp -r ${model_diagnostics_r} $out/model_diagnostics_r
      cp -r ${model_fit_stats_t} $out/model_fit_stats_t
      cp -r ${model_fit_stats_r} $out/model_fit_stats_r
      cp -r ${model_compare_t} $out/model_compare_t
      cp -r ${model_compare_r} $out/model_compare_r
      cp -r ${model_score_t} $out/model_score_t
      cp -r ${model_score_r} $out/model_score_r
      cp -r ${model_anova_t} $out/model_anova_t
      cp -r ${model_anova_r} $out/model_anova_r
      cp -r ${model_wald_t} $out/model_wald_t
      cp -r ${model_wald_r} $out/model_wald_r
      cp -r ${model_scalars_t} $out/model_scalars_t
      cp -r ${model_scalars_r} $out/model_scalars_r
      cp -r ${glm_model_r} $out/glm_model_r
      cp -r ${model_dispersion_t} $out/model_dispersion_t
      cp -r ${model_dispersion_r} $out/model_dispersion_r
      cp -r ${validation} $out/validation
    '';
  };
}

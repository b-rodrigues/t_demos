
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

  raw_data = stdenv.mkDerivation {
    name = "raw_data";
    buildInputs = [ tBin r-env ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
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








      echo "captured_warns <- list()" >> node_script.R
      echo "raw_data <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
df <- data.frame(
                id = 1:5,
                age = c(25, -5, 30, 40, 22),              # Violation: age < 0
                score = c(85, 90, 150, 70, 60),           # Violation: score > 100
                signup_date = c("2023-01-01", "2023-01-10", "2023-02-01", "2023-03-01", "2023-04-01"),
                last_login = c("2023-01-05", "2023-01-08", "2023-02-10", "2023-03-05", "2023-04-10"), # Violation: id=2 login < signup
                email = c("a@b.com", "b@c.com", NA, "d@e.com", "f@g.com"), # Violation: NA in critical field
                stringsAsFactors = FALSE
            )
            df
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
       echo "if (r_is_error(raw_data)) {" >> node_script.R
       echo "  r_write_error(raw_data, file.path(Sys.getenv('out'), 'artifact'))" >> node_script.R
       echo "} else {" >> node_script.R
       cat <<'EOF' >> node_script.R
  r_write_arrow(raw_data, file.path(Sys.getenv('out'), 'artifact'))
EOF
       echo "  writeLines(r_visual_class(raw_data), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  validate_ranges = stdenv.mkDerivation {
    name = "validate_ranges";
    buildInputs = [ tBin raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_raw_data = raw_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import base' >> node_script.t
      echo 'import chrono' >> node_script.t
      echo 'import stats' >> node_script.t


      echo "raw_data = read_arrow(\"$T_NODE_raw_data/artifact\")" >> node_script.t

      echo "      validate_ranges = {" >> node_script.t
      cat <<'EOF' >> node_script.t
-- Perform column-level summaries to check bounds
            s = raw_data |> summarize(
                min_age = min($age),
                max_score = max($score)
            )
            -- Multi-step assertions with descriptive messages
            assert(get(s.min_age, 0) >= 0, "GUARDRAIL FAILURE: Negative age values detected in input data!")
            assert(get(s.max_score, 0) <= 100, "GUARDRAIL FAILURE: Scores exceeding 100 detected!")
            raw_data
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(validate_ranges, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(validate_ranges))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validate_dates = stdenv.mkDerivation {
    name = "validate_dates";
    buildInputs = [ tBin raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_raw_data = raw_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import base' >> node_script.t
      echo 'import chrono' >> node_script.t
      echo 'import stats' >> node_script.t


      echo "raw_data = read_arrow(\"$T_NODE_raw_data/artifact\")" >> node_script.t

      echo "      validate_dates = {" >> node_script.t
      cat <<'EOF' >> node_script.t
violations = raw_data 
                |> mutate(
                    d_signup = ymd($signup_date),
                    d_login = ymd($last_login),
                    is_valid = $d_login >= $d_signup
                )
                |> filter(!$is_valid)
            n_err = nrow(violations)
            assert(n_err == 0, str_join(["GUARDRAIL FAILURE: ", to_string(n_err), " relational date violations detected (login before signup)!"]))
            raw_data
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(validate_dates, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(validate_dates))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validate_nulls = stdenv.mkDerivation {
    name = "validate_nulls";
    buildInputs = [ tBin raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_raw_data = raw_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import base' >> node_script.t
      echo 'import chrono' >> node_script.t
      echo 'import stats' >> node_script.t


      echo "raw_data = read_arrow(\"$T_NODE_raw_data/artifact\")" >> node_script.t

      echo "      validate_nulls = {" >> node_script.t
      cat <<'EOF' >> node_script.t
nas = raw_data |> filter(is_na($email) | is_na($id))
            assert(nrow(nas) == 0, "GUARDRAIL FAILURE: Critical missing values detected in 'id' or 'email' columns!")
            raw_data
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(validate_nulls, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(validate_nulls))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  final_analytics = stdenv.mkDerivation {
    name = "final_analytics";
    buildInputs = [ tBin validate_dates validate_nulls validate_ranges ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_validate_dates = validate_dates;
    T_NODE_validate_nulls = validate_nulls;
    T_NODE_validate_ranges = validate_ranges;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_validate_dates=${validate_dates}
      export T_NODE_validate_nulls=${validate_nulls}
      export T_NODE_validate_ranges=${validate_ranges}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import base' >> node_script.t
      echo 'import chrono' >> node_script.t
      echo 'import stats' >> node_script.t


      echo "validate_dates = deserialize(\"$T_NODE_validate_dates/artifact\")" >> node_script.t
      echo "validate_nulls = deserialize(\"$T_NODE_validate_nulls/artifact\")" >> node_script.t
      echo "validate_ranges = read_arrow(\"$T_NODE_validate_ranges/artifact\")" >> node_script.t

      echo "      final_analytics = {" >> node_script.t
      cat <<'EOF' >> node_script.t
if (is_error(validate_ranges) || is_error(validate_dates) || is_error(validate_nulls)) {
                print("✖ ERROR: One or more data guardrails failed. Analysis aborted.")
                Error("Aborted due to upstream guardrail failures.")
            } else {
                print("✓ SUCCESS: All data guardrails passed. Proceeding with analysis...")
                validate_ranges |> summarize(avg_age = mean($age))
            }
EOF
      echo "      }" >> node_script.t
      echo "      res1 = serialize(final_analytics, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(final_analytics))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin raw_data validate_ranges validate_dates validate_nulls final_analytics ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw_data} $out/raw_data
      cp -r ${validate_ranges} $out/validate_ranges
      cp -r ${validate_dates} $out/validate_dates
      cp -r ${validate_nulls} $out/validate_nulls
      cp -r ${final_analytics} $out/final_analytics
    '';
  };
}

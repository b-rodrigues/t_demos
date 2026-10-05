
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
  
    rSerializerPackages = [ "dplyr" "jsonlite" ];
    pySerializerPackages = [  ];
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
  env_github_nixos_nixpkgs_nixos_24_11 = mkNodeEnv "github:NixOS/nixpkgs/nixos-24.11";
  env_github_b_rodrigues_tlang = mkNodeEnv "github:b-rodrigues/tlang";
  env_github_jbedo_rshells = mkNodeEnv "github:jbedo/rshells";
  env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake = mkNodeEnv "path:/home/runner/work/t_demos/t_demos/per_node_flake_t/test_flake";
  env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake = mkNodeEnv "path:/home/runner/work/t_demos/t_demos/per_node_flake_t/minimal_r_flake";
in
rec {

  a = stdenv.mkDerivation {
    name = "a";
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
      __node_result = sum([1, 2, 3, 4, 5])
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  b = env_github_b_rodrigues_tlang.stdenv.mkDerivation {
    name = "b";
    buildInputs = [ env_github_b_rodrigues_tlang.tBin  ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_github_b_rodrigues_tlang.pkgs ? jpmml-statsmodels) then "${env_github_b_rodrigues_tlang.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_github_b_rodrigues_tlang.pkgs ? jpmml-evaluator) then "${env_github_b_rodrigues_tlang.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_github_b_rodrigues_tlang.pkgs.gcc.cc.lib}/lib:${env_github_b_rodrigues_tlang.pkgs.avahi}/lib";
    PYTHONPATH = "${env_github_b_rodrigues_tlang.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_github_b_rodrigues_tlang.tlangJl}";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t

EOF














      cat <<'EOF' >> node_script.t
      __node_result = length([10, 20, 30, 40])
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  c = env_github_jbedo_rshells.stdenv.mkDerivation {
    name = "c";
    buildInputs = [ env_github_jbedo_rshells.tBin env_github_jbedo_rshells.r-env ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_github_jbedo_rshells.pkgs ? jpmml-statsmodels) then "${env_github_jbedo_rshells.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_github_jbedo_rshells.pkgs ? jpmml-evaluator) then "${env_github_jbedo_rshells.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_github_jbedo_rshells.pkgs.gcc.cc.lib}/lib:${env_github_jbedo_rshells.pkgs.avahi}/lib";
    PYTHONPATH = "${env_github_jbedo_rshells.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_github_jbedo_rshells.tlangJl}";
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF











      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
mean(mtcars$mpg)
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
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  d = env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.stdenv.mkDerivation {
    name = "d";
    buildInputs = [ env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.tBin  ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs ? jpmml-statsmodels) then "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs ? jpmml-evaluator) then "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs.gcc.cc.lib}/lib:${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.pkgs.avahi}/lib";
    PYTHONPATH = "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_test_flake.tlangJl}";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t

EOF














      cat <<'EOF' >> node_script.t
      __node_result = ([1, 2, 3] |> map(\(x) (x * 10)))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  e = env_github_nixos_nixpkgs_nixos_24_11.stdenv.mkDerivation {
    name = "e";
    buildInputs = [ env_github_nixos_nixpkgs_nixos_24_11.tBin env_github_nixos_nixpkgs_nixos_24_11.juliaPkg ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_github_nixos_nixpkgs_nixos_24_11.pkgs ? jpmml-statsmodels) then "${env_github_nixos_nixpkgs_nixos_24_11.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_github_nixos_nixpkgs_nixos_24_11.pkgs ? jpmml-evaluator) then "${env_github_nixos_nixpkgs_nixos_24_11.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_github_nixos_nixpkgs_nixos_24_11.pkgs.gcc.cc.lib}/lib:${env_github_nixos_nixpkgs_nixos_24_11.pkgs.avahi}/lib";
    PYTHONPATH = "${env_github_nixos_nixpkgs_nixos_24_11.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_github_nixos_nixpkgs_nixos_24_11.tlangJl}";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

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











      echo "captured_logger = TCaptureLogger()" >> node_script.jl
      echo "try" >> node_script.jl
      echo "    local __tlang_node_thunk = () -> begin" >> node_script.jl
      cat <<'EOF' >> node_script.jl
            sum([1, 2, 3, 4, 5]) / length([1, 2, 3, 4, 5])
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
 

  f = env_github_jbedo_rshells.stdenv.mkDerivation {
    name = "f";
    buildInputs = [ env_github_jbedo_rshells.tBin env_github_jbedo_rshells.r-env ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_github_jbedo_rshells.pkgs ? jpmml-statsmodels) then "${env_github_jbedo_rshells.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_github_jbedo_rshells.pkgs ? jpmml-evaluator) then "${env_github_jbedo_rshells.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_github_jbedo_rshells.pkgs.gcc.cc.lib}/lib:${env_github_jbedo_rshells.pkgs.avahi}/lib";
    PYTHONPATH = "${env_github_jbedo_rshells.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_github_jbedo_rshells.tlangJl}";
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF











      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
if (require(dplyr, quietly = TRUE)) {
        "dplyr IS available on rshells flake"
      } else {
        "dplyr IS NOT available on rshells flake"
      }
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
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  g = env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.stdenv.mkDerivation {
    name = "g";
    buildInputs = [ env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.tBin env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.r-env ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs ? jpmml-statsmodels) then "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs ? jpmml-evaluator) then "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs.gcc.cc.lib}/lib:${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.pkgs.avahi}/lib";
    PYTHONPATH = "${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${env_path_home_runner_work_t_demos_t_demos_per_node_flake_t_minimal_r_flake.tlangJl}";
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

r_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
}
r_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF











      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
if (require(dplyr, quietly = TRUE)) {
        "dplyr IS available in this node"
      } else {
        "dplyr is NOT available in this node"
      }
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
    buildInputs = [ tBin a b c d e f g projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${a} $out/a
      cp -r ${b} $out/b
      cp -r ${c} $out/c
      cp -r ${d} $out/d
      cp -r ${e} $out/e
      cp -r ${f} $out/f
      cp -r ${g} $out/g
    '';
  };
}

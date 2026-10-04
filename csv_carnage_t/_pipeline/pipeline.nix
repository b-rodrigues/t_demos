
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

  test_empty = stdenv.mkDerivation {
    name = "test_empty";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { write_text("empty.csv", ""); (read_csv("empty.csv") ?|> \(x) if (is_error(x)) { [test: "empty_file", passed: false, status: "error", code: error_code(x)] } else { [test: "empty_file", passed: (nrow(x) == 0), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_header_only = stdenv.mkDerivation {
    name = "test_header_only";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { write_text("header_only.csv", "a,b,c\n"); df = read_csv("header_only.csv"); [test: "header_only", passed: ((nrow(df) == 0) && (ncol(df) == 3)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_ragged = stdenv.mkDerivation {
    name = "test_ragged";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { write_text("ragged.csv", "a,b,c\n1,2\n3,4,5,6\n7,8,9,10,11"); (read_csv("ragged.csv") ?|> \(x) if (is_error(x)) { [test: "ragged_rows", passed: true, status: "error", code: error_code(x)] } else { [test: "ragged_rows", passed: false, status: "unexpected_ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_weird_delimiters = stdenv.mkDerivation {
    name = "test_weird_delimiters";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["a,b,c\n", "1,2,\n", ",4,5\n", "6,,7\n"]); write_text("weird_delim.csv", content); result = read_csv("weird_delim.csv"); (result ?|> \(x) if (is_error(x)) { [test: "weird_delimiters", passed: true, status: "error", code: error_code(x)] } else { [test: "weird_delimiters", passed: true, status: "ok", rows: nrow(x), cols: ncol(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_bom = stdenv.mkDerivation {
    name = "test_bom";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["﻿", "a,b\n1,2\n"]); write_text("bom.csv", content); result = read_csv("bom.csv"); (result ?|> \(x) if (is_error(x)) { [test: "bom_prefix", passed: true, status: "error", code: error_code(x)] } else { [test: "bom_prefix", passed: true, status: "ok", rows: nrow(x), cols: ncol(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_weird_colnames = stdenv.mkDerivation {
    name = "test_weird_colnames";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["\"%growth\",\"$price\",\"€uro\",\"col name\",\"123start\",\"\",a,a\n", "1,2,3,4,5,6,7,8\n"]); write_text("weird_colnames.csv", content); result = read_csv("weird_colnames.csv"); (result ?|> \(x) if (is_error(x)) { [test: "weird_colnames", passed: true, status: "error", code: error_code(x)] } else { [test: "weird_colnames", passed: (ncol(x) == 8), status: "ok", cols: ncol(x), names: colnames(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_mixed_types = stdenv.mkDerivation {
    name = "test_mixed_types";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["val\n", "42\n", "hello\n", "\n"]); write_text("mixed_types.csv", content); df = read_csv("mixed_types.csv"); [test: "mixed_types", passed: (nrow(df) == 2), status: "ok", rows: nrow(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_unicode_values = stdenv.mkDerivation {
    name = "test_unicode_values";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["label,value\n", "\"café\",1\n", "\"naïve\",2\n", "\"中文\",3\n", "\"😀\",4\n"]); write_text("unicode.csv", content); df = read_csv("unicode.csv"); [test: "unicode_values", passed: (nrow(df) == 4), status: "ok", rows: nrow(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_quoted_newlines = stdenv.mkDerivation {
    name = "test_quoted_newlines";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["id,note\n", "1,\"line1\n", "line2\"\n", "2,\"single\"\n"]); write_text("newlines.csv", content); result = read_csv("newlines.csv"); (result ?|> \(x) if (is_error(x)) { [test: "quoted_newlines", passed: true, status: "error", code: error_code(x)] } else { [test: "quoted_newlines", passed: (nrow(x) == 2), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_tab_sep = stdenv.mkDerivation {
    name = "test_tab_sep";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["a\tb\tc\n", "1\t2\t3\n", "4\t5\t6\n"]); write_text("tab.csv", content); df = read_csv("tab.csv", separator = "\t"); [test: "tab_separator", passed: ((nrow(df) == 2) && (ncol(df) == 3)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_semicolon_sep = stdenv.mkDerivation {
    name = "test_semicolon_sep";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["a;b;c\n", "1;2;3\n", "4;5;6\n"]); write_text("semicolon.csv", content); df = read_csv("semicolon.csv", separator = ";"); [test: "semicolon_separator", passed: ((nrow(df) == 2) && (ncol(df) == 3)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_clean_colnames = stdenv.mkDerivation {
    name = "test_clean_colnames";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["\"%growth\",\"$price\",\"€uro\",\"col name\",\"123start\"\n", "1,2,3,4,5\n"]); write_text("clean_me.csv", content); df = read_csv("clean_me.csv", clean_colnames = true); names = colnames(df); passed = (ncol(df) == 5); [test: "clean_colnames", passed: passed, status: "ok", names: names] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_skip = stdenv.mkDerivation {
    name = "test_skip";
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









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = { content = str_join(["garbage line\n", "more garbage\n", "a,b,c\n", "1,2,3\n", "4,5,6\n"]); write_text("skip.csv", content); df = read_csv("skip.csv", skip_lines = 2, skip_header = true); [test: "skip_options", passed: ((nrow(df) == 3) && (ncol(df) == 3)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validation = stdenv.mkDerivation {
    name = "validation";
    buildInputs = [ tBin test_bom test_clean_colnames test_empty test_header_only test_mixed_types test_quoted_newlines test_ragged test_semicolon_sep test_skip test_tab_sep test_unicode_values test_weird_colnames test_weird_delimiters ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_test_bom = test_bom;
    T_INPUT_test_bom = "${test_bom}/artifact";
    T_NODE_test_clean_colnames = test_clean_colnames;
    T_INPUT_test_clean_colnames = "${test_clean_colnames}/artifact";
    T_NODE_test_empty = test_empty;
    T_INPUT_test_empty = "${test_empty}/artifact";
    T_NODE_test_header_only = test_header_only;
    T_INPUT_test_header_only = "${test_header_only}/artifact";
    T_NODE_test_mixed_types = test_mixed_types;
    T_INPUT_test_mixed_types = "${test_mixed_types}/artifact";
    T_NODE_test_quoted_newlines = test_quoted_newlines;
    T_INPUT_test_quoted_newlines = "${test_quoted_newlines}/artifact";
    T_NODE_test_ragged = test_ragged;
    T_INPUT_test_ragged = "${test_ragged}/artifact";
    T_NODE_test_semicolon_sep = test_semicolon_sep;
    T_INPUT_test_semicolon_sep = "${test_semicolon_sep}/artifact";
    T_NODE_test_skip = test_skip;
    T_INPUT_test_skip = "${test_skip}/artifact";
    T_NODE_test_tab_sep = test_tab_sep;
    T_INPUT_test_tab_sep = "${test_tab_sep}/artifact";
    T_NODE_test_unicode_values = test_unicode_values;
    T_INPUT_test_unicode_values = "${test_unicode_values}/artifact";
    T_NODE_test_weird_colnames = test_weird_colnames;
    T_INPUT_test_weird_colnames = "${test_weird_colnames}/artifact";
    T_NODE_test_weird_delimiters = test_weird_delimiters;
    T_INPUT_test_weird_delimiters = "${test_weird_delimiters}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_test_bom=${test_bom}
      export T_INPUT_test_bom=${test_bom}/artifact
      export T_NODE_test_clean_colnames=${test_clean_colnames}
      export T_INPUT_test_clean_colnames=${test_clean_colnames}/artifact
      export T_NODE_test_empty=${test_empty}
      export T_INPUT_test_empty=${test_empty}/artifact
      export T_NODE_test_header_only=${test_header_only}
      export T_INPUT_test_header_only=${test_header_only}/artifact
      export T_NODE_test_mixed_types=${test_mixed_types}
      export T_INPUT_test_mixed_types=${test_mixed_types}/artifact
      export T_NODE_test_quoted_newlines=${test_quoted_newlines}
      export T_INPUT_test_quoted_newlines=${test_quoted_newlines}/artifact
      export T_NODE_test_ragged=${test_ragged}
      export T_INPUT_test_ragged=${test_ragged}/artifact
      export T_NODE_test_semicolon_sep=${test_semicolon_sep}
      export T_INPUT_test_semicolon_sep=${test_semicolon_sep}/artifact
      export T_NODE_test_skip=${test_skip}
      export T_INPUT_test_skip=${test_skip}/artifact
      export T_NODE_test_tab_sep=${test_tab_sep}
      export T_INPUT_test_tab_sep=${test_tab_sep}/artifact
      export T_NODE_test_unicode_values=${test_unicode_values}
      export T_INPUT_test_unicode_values=${test_unicode_values}/artifact
      export T_NODE_test_weird_colnames=${test_weird_colnames}
      export T_INPUT_test_weird_colnames=${test_weird_colnames}/artifact
      export T_NODE_test_weird_delimiters=${test_weird_delimiters}
      export T_INPUT_test_weird_delimiters=${test_weird_delimiters}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t


      echo "if (file_exists(\"$T_NODE_test_bom/class\") && (read_file(\"$T_NODE_test_bom/class\") == \"VError\" || read_file(\"$T_NODE_test_bom/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_bom/class\") == \"Error\" || read_file(\"$T_NODE_test_bom/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_bom = deserialize(\"$T_NODE_test_bom/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_bom = deserialize(\"$T_NODE_test_bom/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_clean_colnames/class\") && (read_file(\"$T_NODE_test_clean_colnames/class\") == \"VError\" || read_file(\"$T_NODE_test_clean_colnames/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_clean_colnames/class\") == \"Error\" || read_file(\"$T_NODE_test_clean_colnames/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_clean_colnames = deserialize(\"$T_NODE_test_clean_colnames/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_clean_colnames = deserialize(\"$T_NODE_test_clean_colnames/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_empty/class\") && (read_file(\"$T_NODE_test_empty/class\") == \"VError\" || read_file(\"$T_NODE_test_empty/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_empty/class\") == \"Error\" || read_file(\"$T_NODE_test_empty/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_empty = deserialize(\"$T_NODE_test_empty/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_empty = deserialize(\"$T_NODE_test_empty/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_header_only/class\") && (read_file(\"$T_NODE_test_header_only/class\") == \"VError\" || read_file(\"$T_NODE_test_header_only/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_header_only/class\") == \"Error\" || read_file(\"$T_NODE_test_header_only/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_header_only = deserialize(\"$T_NODE_test_header_only/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_header_only = deserialize(\"$T_NODE_test_header_only/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_mixed_types/class\") && (read_file(\"$T_NODE_test_mixed_types/class\") == \"VError\" || read_file(\"$T_NODE_test_mixed_types/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_mixed_types/class\") == \"Error\" || read_file(\"$T_NODE_test_mixed_types/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_mixed_types = deserialize(\"$T_NODE_test_mixed_types/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_mixed_types = deserialize(\"$T_NODE_test_mixed_types/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_quoted_newlines/class\") && (read_file(\"$T_NODE_test_quoted_newlines/class\") == \"VError\" || read_file(\"$T_NODE_test_quoted_newlines/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_quoted_newlines/class\") == \"Error\" || read_file(\"$T_NODE_test_quoted_newlines/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_quoted_newlines = deserialize(\"$T_NODE_test_quoted_newlines/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_quoted_newlines = deserialize(\"$T_NODE_test_quoted_newlines/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_ragged/class\") && (read_file(\"$T_NODE_test_ragged/class\") == \"VError\" || read_file(\"$T_NODE_test_ragged/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_ragged/class\") == \"Error\" || read_file(\"$T_NODE_test_ragged/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_ragged = deserialize(\"$T_NODE_test_ragged/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_ragged = deserialize(\"$T_NODE_test_ragged/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_semicolon_sep/class\") && (read_file(\"$T_NODE_test_semicolon_sep/class\") == \"VError\" || read_file(\"$T_NODE_test_semicolon_sep/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_semicolon_sep/class\") == \"Error\" || read_file(\"$T_NODE_test_semicolon_sep/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_semicolon_sep = deserialize(\"$T_NODE_test_semicolon_sep/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_semicolon_sep = deserialize(\"$T_NODE_test_semicolon_sep/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_skip/class\") && (read_file(\"$T_NODE_test_skip/class\") == \"VError\" || read_file(\"$T_NODE_test_skip/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_skip/class\") == \"Error\" || read_file(\"$T_NODE_test_skip/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_skip = deserialize(\"$T_NODE_test_skip/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_skip = deserialize(\"$T_NODE_test_skip/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_tab_sep/class\") && (read_file(\"$T_NODE_test_tab_sep/class\") == \"VError\" || read_file(\"$T_NODE_test_tab_sep/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_tab_sep/class\") == \"Error\" || read_file(\"$T_NODE_test_tab_sep/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_tab_sep = deserialize(\"$T_NODE_test_tab_sep/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_tab_sep = deserialize(\"$T_NODE_test_tab_sep/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_unicode_values/class\") && (read_file(\"$T_NODE_test_unicode_values/class\") == \"VError\" || read_file(\"$T_NODE_test_unicode_values/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_unicode_values/class\") == \"Error\" || read_file(\"$T_NODE_test_unicode_values/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_unicode_values = deserialize(\"$T_NODE_test_unicode_values/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_unicode_values = deserialize(\"$T_NODE_test_unicode_values/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_weird_colnames/class\") && (read_file(\"$T_NODE_test_weird_colnames/class\") == \"VError\" || read_file(\"$T_NODE_test_weird_colnames/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_weird_colnames/class\") == \"Error\" || read_file(\"$T_NODE_test_weird_colnames/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_weird_colnames = deserialize(\"$T_NODE_test_weird_colnames/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_weird_colnames = deserialize(\"$T_NODE_test_weird_colnames/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_weird_delimiters/class\") && (read_file(\"$T_NODE_test_weird_delimiters/class\") == \"VError\" || read_file(\"$T_NODE_test_weird_delimiters/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_weird_delimiters/class\") == \"Error\" || read_file(\"$T_NODE_test_weird_delimiters/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_weird_delimiters = deserialize(\"$T_NODE_test_weird_delimiters/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_weird_delimiters = deserialize(\"$T_NODE_test_weird_delimiters/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
test_weird_delimiters = __dep_test_weird_delimiters
EOF
      cat <<'EOF' >> node_script.t
test_weird_colnames = __dep_test_weird_colnames
EOF
      cat <<'EOF' >> node_script.t
test_unicode_values = __dep_test_unicode_values
EOF
      cat <<'EOF' >> node_script.t
test_tab_sep = __dep_test_tab_sep
EOF
      cat <<'EOF' >> node_script.t
test_skip = __dep_test_skip
EOF
      cat <<'EOF' >> node_script.t
test_semicolon_sep = __dep_test_semicolon_sep
EOF
      cat <<'EOF' >> node_script.t
test_ragged = __dep_test_ragged
EOF
      cat <<'EOF' >> node_script.t
test_quoted_newlines = __dep_test_quoted_newlines
EOF
      cat <<'EOF' >> node_script.t
test_mixed_types = __dep_test_mixed_types
EOF
      cat <<'EOF' >> node_script.t
test_header_only = __dep_test_header_only
EOF
      cat <<'EOF' >> node_script.t
test_empty = __dep_test_empty
EOF
      cat <<'EOF' >> node_script.t
test_clean_colnames = __dep_test_clean_colnames
EOF
      cat <<'EOF' >> node_script.t
test_bom = __dep_test_bom
EOF

      cat <<'EOF' >> node_script.t
      __node_result = { results = [test_empty, test_header_only, test_ragged, test_weird_delimiters, test_bom, test_weird_colnames, test_mixed_types, test_unicode_values, test_quoted_newlines, test_tab_sep, test_semicolon_sep, test_clean_colnames, test_skip]; failures = ((results |> to_dataframe) |> filter(($passed == false))); n_fail = nrow(failures); if ((n_fail > 0)) { print("FAILURES:"); print(failures); assert((n_fail == 0), str_sprintf("csv_carnage_t: %d tests failed", n_fail)) } else NA; [status: "ok", total: 13, passed: (13 - n_fail), failures: n_fail] }
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
    buildInputs = [ tBin test_empty test_header_only test_ragged test_weird_delimiters test_bom test_weird_colnames test_mixed_types test_unicode_values test_quoted_newlines test_tab_sep test_semicolon_sep test_clean_colnames test_skip validation projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${test_empty} $out/test_empty
      cp -r ${test_header_only} $out/test_header_only
      cp -r ${test_ragged} $out/test_ragged
      cp -r ${test_weird_delimiters} $out/test_weird_delimiters
      cp -r ${test_bom} $out/test_bom
      cp -r ${test_weird_colnames} $out/test_weird_colnames
      cp -r ${test_mixed_types} $out/test_mixed_types
      cp -r ${test_unicode_values} $out/test_unicode_values
      cp -r ${test_quoted_newlines} $out/test_quoted_newlines
      cp -r ${test_tab_sep} $out/test_tab_sep
      cp -r ${test_semicolon_sep} $out/test_semicolon_sep
      cp -r ${test_clean_colnames} $out/test_clean_colnames
      cp -r ${test_skip} $out/test_skip
      cp -r ${validation} $out/validation
    '';
  };
}

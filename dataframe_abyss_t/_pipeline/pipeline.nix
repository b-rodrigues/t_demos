
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
      __node_result = { df = to_dataframe([]); [test: "empty_df", passed: ((nrow(df) == 0) && (ncol(df) == 0)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_all_na = stdenv.mkDerivation {
    name = "test_all_na";
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
      __node_result = { df = to_dataframe([[i: na_int(), f: na_float(), b: na_bool(), s: na_string()], [i: na_int(), f: na_float(), b: na_bool(), s: na_string()]]); all_na = (((is_na((pull(df, $i) |> get(0))) && is_na((pull(df, $f) |> get(0)))) && is_na((pull(df, $b) |> get(0)))) && is_na((pull(df, $s) |> get(0)))); [test: "all_na_df", passed: ((all_na && (nrow(df) == 2)) && (ncol(df) == 4)), rows: nrow(df), cols: ncol(df)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_single_cell = stdenv.mkDerivation {
    name = "test_single_cell";
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
      __node_result = { df = to_dataframe([[x: 42]]); val = (pull(df, $x) |> get(0)); [test: "single_cell", passed: (((nrow(df) == 1) && (ncol(df) == 1)) && (val == 42)), rows: nrow(df), cols: ncol(df), value: val] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_dup_colnames = stdenv.mkDerivation {
    name = "test_dup_colnames";
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
      __node_result = { df = to_dataframe([[a: 1, b: 2], [a: 3, b: 4]]); risky = rename(df, a = $b); (risky ?|> \(r) { if (is_error(r)) { [test: "dup_colnames", passed: true, status: "error", code: error_code(r)] } else { [test: "dup_colnames", passed: (ncol(r) == 2), status: "ok", cols: colnames(r)] } }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_long_colname = stdenv.mkDerivation {
    name = "test_long_colname";
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
      __node_result = { long = ((seq(1, 100) |> map(\(x) to_string(x))) |> str_join(sep = "")); header = str_join(["short,", long, "\n"]); content = str_join([header, "1,2\n"]); write_text("long_col.csv", content); df = read_csv("long_col.csv"); names = colnames(df); name_len = str_nchar(get(names, 1)); [test: "long_colname", passed: (name_len == 192), name_len: name_len] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_na_filter = stdenv.mkDerivation {
    name = "test_na_filter";
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
      __node_result = { df = to_dataframe([[id: 1, val: 10.], [id: 2, val: na_float()], [id: 3, val: 30.]]); risky = (df |> filter(($val > 15))); (risky ?|> \(x) if (is_error(x)) { [test: "na_filter", passed: true, status: "error", code: error_code(x)] } else { [test: "na_filter", passed: (nrow(x) == 1), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_na_arithmetic = stdenv.mkDerivation {
    name = "test_na_arithmetic";
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
      __node_result = { df = to_dataframe([[id: 1, val: na_float()], [id: 2, val: 5.]]); risky = (df |> mutate(new = ($val + 1))); (risky ?|> \(x) if (is_error(x)) { [test: "na_arithmetic", passed: true, status: "error", code: error_code(x)] } else { [test: "na_arithmetic", passed: (nrow(x) == 2), status: "ok"] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_coerce_mutate = stdenv.mkDerivation {
    name = "test_coerce_mutate";
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
      __node_result = { df = to_dataframe([[a: 1, b: 2.5], [a: 3, b: 4.5]]); risky = (df |> mutate(c = ($a + $b))); (risky ?|> \(x) if (is_error(x)) { [test: "coerce_mutate", passed: true, status: "error", code: error_code(x)] } else { [test: "coerce_mutate", passed: ((nrow(x) == 2) && (ncol(x) == 3)), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_coerce_bind = stdenv.mkDerivation {
    name = "test_coerce_bind";
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
      __node_result = { df1 = to_dataframe([[x: 1, y: "a"]]); df2 = to_dataframe([[x: "two", y: 2]]); risky = bind_rows(df1, df2); (risky ?|> \(x) if (is_error(x)) { [test: "coerce_bind", passed: true, status: "error", code: error_code(x)] } else { [test: "coerce_bind", passed: (nrow(x) == 2), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_pivot_dup_keys = stdenv.mkDerivation {
    name = "test_pivot_dup_keys";
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
      __node_result = { df = to_dataframe([[id: 1, key: "k", val: 10], [id: 1, key: "k", val: 20]]); risky = (df |> pivot_wider(names_from = $key, values_from = $val)); (risky ?|> \(x) if (is_error(x)) { [test: "pivot_dup_keys", passed: true, status: "error", code: error_code(x)] } else { [test: "pivot_dup_keys", passed: (nrow(x) == 1), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_pivot_longer = stdenv.mkDerivation {
    name = "test_pivot_longer";
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
      __node_result = { df = to_dataframe([[id: 1, a: 10, b: 20], [id: 2, a: 30, b: 40]]); risky = (df |> pivot_longer(cols = [$a, $b], names_to = "key", values_to = "val")); (risky ?|> \(x) if (is_error(x)) { [test: "pivot_longer", passed: true, status: "error", code: error_code(x)] } else { [test: "pivot_longer", passed: ((nrow(x) == 4) && (ncol(x) == 3)), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_group_by_na = stdenv.mkDerivation {
    name = "test_group_by_na";
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
      __node_result = { df = to_dataframe([[g: "a", v: 1], [g: na_string(), v: 2], [g: "b", v: 3]]); risky = ((df |> group_by($g)) |> summarize(total = sum($v, na_rm = true))); (risky ?|> \(x) if (is_error(x)) { [test: "group_by_na", passed: true, status: "error", code: error_code(x)] } else { [test: "group_by_na", passed: (nrow(x) == 3), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_empty_grouped = stdenv.mkDerivation {
    name = "test_empty_grouped";
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
      __node_result = { df = to_dataframe([[g: "a", v: 1], [g: "b", v: 2]]); risky = (((df |> filter(($g == "nonexistent"))) |> group_by($g)) |> summarize(total = sum($v, na_rm = true))); (risky ?|> \(x) if (is_error(x)) { [test: "empty_grouped", passed: true, status: "error", code: error_code(x)] } else { [test: "empty_grouped", passed: (nrow(x) == 0), status: "ok", rows: nrow(x)] }) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_zero_cols = stdenv.mkDerivation {
    name = "test_zero_cols";
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
      __node_result = { df = to_dataframe([[a: 1, b: 2]]); risky = (df |> select()); (risky ?|> \(x) if (is_error(x)) { [test: "zero_cols", passed: true, status: "error", code: error_code(x)] } else { [test: "zero_cols", passed: (ncol(x) == 0), status: "ok", cols: ncol(x)] }) }
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
    buildInputs = [ tBin test_all_na test_coerce_bind test_coerce_mutate test_dup_colnames test_empty test_empty_grouped test_group_by_na test_long_colname test_na_arithmetic test_na_filter test_pivot_dup_keys test_pivot_longer test_single_cell test_zero_cols ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_test_all_na = test_all_na;
    T_INPUT_test_all_na = "${test_all_na}/artifact";
    T_NODE_test_coerce_bind = test_coerce_bind;
    T_INPUT_test_coerce_bind = "${test_coerce_bind}/artifact";
    T_NODE_test_coerce_mutate = test_coerce_mutate;
    T_INPUT_test_coerce_mutate = "${test_coerce_mutate}/artifact";
    T_NODE_test_dup_colnames = test_dup_colnames;
    T_INPUT_test_dup_colnames = "${test_dup_colnames}/artifact";
    T_NODE_test_empty = test_empty;
    T_INPUT_test_empty = "${test_empty}/artifact";
    T_NODE_test_empty_grouped = test_empty_grouped;
    T_INPUT_test_empty_grouped = "${test_empty_grouped}/artifact";
    T_NODE_test_group_by_na = test_group_by_na;
    T_INPUT_test_group_by_na = "${test_group_by_na}/artifact";
    T_NODE_test_long_colname = test_long_colname;
    T_INPUT_test_long_colname = "${test_long_colname}/artifact";
    T_NODE_test_na_arithmetic = test_na_arithmetic;
    T_INPUT_test_na_arithmetic = "${test_na_arithmetic}/artifact";
    T_NODE_test_na_filter = test_na_filter;
    T_INPUT_test_na_filter = "${test_na_filter}/artifact";
    T_NODE_test_pivot_dup_keys = test_pivot_dup_keys;
    T_INPUT_test_pivot_dup_keys = "${test_pivot_dup_keys}/artifact";
    T_NODE_test_pivot_longer = test_pivot_longer;
    T_INPUT_test_pivot_longer = "${test_pivot_longer}/artifact";
    T_NODE_test_single_cell = test_single_cell;
    T_INPUT_test_single_cell = "${test_single_cell}/artifact";
    T_NODE_test_zero_cols = test_zero_cols;
    T_INPUT_test_zero_cols = "${test_zero_cols}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_test_all_na=${test_all_na}
      export T_INPUT_test_all_na=${test_all_na}/artifact
      export T_NODE_test_coerce_bind=${test_coerce_bind}
      export T_INPUT_test_coerce_bind=${test_coerce_bind}/artifact
      export T_NODE_test_coerce_mutate=${test_coerce_mutate}
      export T_INPUT_test_coerce_mutate=${test_coerce_mutate}/artifact
      export T_NODE_test_dup_colnames=${test_dup_colnames}
      export T_INPUT_test_dup_colnames=${test_dup_colnames}/artifact
      export T_NODE_test_empty=${test_empty}
      export T_INPUT_test_empty=${test_empty}/artifact
      export T_NODE_test_empty_grouped=${test_empty_grouped}
      export T_INPUT_test_empty_grouped=${test_empty_grouped}/artifact
      export T_NODE_test_group_by_na=${test_group_by_na}
      export T_INPUT_test_group_by_na=${test_group_by_na}/artifact
      export T_NODE_test_long_colname=${test_long_colname}
      export T_INPUT_test_long_colname=${test_long_colname}/artifact
      export T_NODE_test_na_arithmetic=${test_na_arithmetic}
      export T_INPUT_test_na_arithmetic=${test_na_arithmetic}/artifact
      export T_NODE_test_na_filter=${test_na_filter}
      export T_INPUT_test_na_filter=${test_na_filter}/artifact
      export T_NODE_test_pivot_dup_keys=${test_pivot_dup_keys}
      export T_INPUT_test_pivot_dup_keys=${test_pivot_dup_keys}/artifact
      export T_NODE_test_pivot_longer=${test_pivot_longer}
      export T_INPUT_test_pivot_longer=${test_pivot_longer}/artifact
      export T_NODE_test_single_cell=${test_single_cell}
      export T_INPUT_test_single_cell=${test_single_cell}/artifact
      export T_NODE_test_zero_cols=${test_zero_cols}
      export T_INPUT_test_zero_cols=${test_zero_cols}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import colcraft' >> node_script.t
      echo 'import dataframe' >> node_script.t


      echo "if (file_exists(\"$T_NODE_test_all_na/class\") && (read_file(\"$T_NODE_test_all_na/class\") == \"VError\" || read_file(\"$T_NODE_test_all_na/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_all_na/class\") == \"Error\" || read_file(\"$T_NODE_test_all_na/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_all_na = deserialize(\"$T_NODE_test_all_na/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_all_na = deserialize(\"$T_NODE_test_all_na/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_coerce_bind/class\") && (read_file(\"$T_NODE_test_coerce_bind/class\") == \"VError\" || read_file(\"$T_NODE_test_coerce_bind/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_coerce_bind/class\") == \"Error\" || read_file(\"$T_NODE_test_coerce_bind/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_coerce_bind = deserialize(\"$T_NODE_test_coerce_bind/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_coerce_bind = deserialize(\"$T_NODE_test_coerce_bind/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_coerce_mutate/class\") && (read_file(\"$T_NODE_test_coerce_mutate/class\") == \"VError\" || read_file(\"$T_NODE_test_coerce_mutate/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_coerce_mutate/class\") == \"Error\" || read_file(\"$T_NODE_test_coerce_mutate/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_coerce_mutate = deserialize(\"$T_NODE_test_coerce_mutate/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_coerce_mutate = deserialize(\"$T_NODE_test_coerce_mutate/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_dup_colnames/class\") && (read_file(\"$T_NODE_test_dup_colnames/class\") == \"VError\" || read_file(\"$T_NODE_test_dup_colnames/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_dup_colnames/class\") == \"Error\" || read_file(\"$T_NODE_test_dup_colnames/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_dup_colnames = deserialize(\"$T_NODE_test_dup_colnames/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_dup_colnames = deserialize(\"$T_NODE_test_dup_colnames/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_empty/class\") && (read_file(\"$T_NODE_test_empty/class\") == \"VError\" || read_file(\"$T_NODE_test_empty/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_empty/class\") == \"Error\" || read_file(\"$T_NODE_test_empty/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_empty = deserialize(\"$T_NODE_test_empty/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_empty = deserialize(\"$T_NODE_test_empty/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_empty_grouped/class\") && (read_file(\"$T_NODE_test_empty_grouped/class\") == \"VError\" || read_file(\"$T_NODE_test_empty_grouped/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_empty_grouped/class\") == \"Error\" || read_file(\"$T_NODE_test_empty_grouped/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_empty_grouped = deserialize(\"$T_NODE_test_empty_grouped/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_empty_grouped = deserialize(\"$T_NODE_test_empty_grouped/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_group_by_na/class\") && (read_file(\"$T_NODE_test_group_by_na/class\") == \"VError\" || read_file(\"$T_NODE_test_group_by_na/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_group_by_na/class\") == \"Error\" || read_file(\"$T_NODE_test_group_by_na/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_group_by_na = deserialize(\"$T_NODE_test_group_by_na/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_group_by_na = deserialize(\"$T_NODE_test_group_by_na/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_long_colname/class\") && (read_file(\"$T_NODE_test_long_colname/class\") == \"VError\" || read_file(\"$T_NODE_test_long_colname/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_long_colname/class\") == \"Error\" || read_file(\"$T_NODE_test_long_colname/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_long_colname = deserialize(\"$T_NODE_test_long_colname/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_long_colname = deserialize(\"$T_NODE_test_long_colname/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_na_arithmetic/class\") && (read_file(\"$T_NODE_test_na_arithmetic/class\") == \"VError\" || read_file(\"$T_NODE_test_na_arithmetic/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_na_arithmetic/class\") == \"Error\" || read_file(\"$T_NODE_test_na_arithmetic/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_na_arithmetic = deserialize(\"$T_NODE_test_na_arithmetic/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_na_arithmetic = deserialize(\"$T_NODE_test_na_arithmetic/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_na_filter/class\") && (read_file(\"$T_NODE_test_na_filter/class\") == \"VError\" || read_file(\"$T_NODE_test_na_filter/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_na_filter/class\") == \"Error\" || read_file(\"$T_NODE_test_na_filter/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_na_filter = deserialize(\"$T_NODE_test_na_filter/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_na_filter = deserialize(\"$T_NODE_test_na_filter/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_pivot_dup_keys/class\") && (read_file(\"$T_NODE_test_pivot_dup_keys/class\") == \"VError\" || read_file(\"$T_NODE_test_pivot_dup_keys/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_pivot_dup_keys/class\") == \"Error\" || read_file(\"$T_NODE_test_pivot_dup_keys/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_pivot_dup_keys = deserialize(\"$T_NODE_test_pivot_dup_keys/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_pivot_dup_keys = deserialize(\"$T_NODE_test_pivot_dup_keys/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_pivot_longer/class\") && (read_file(\"$T_NODE_test_pivot_longer/class\") == \"VError\" || read_file(\"$T_NODE_test_pivot_longer/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_pivot_longer/class\") == \"Error\" || read_file(\"$T_NODE_test_pivot_longer/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_pivot_longer = deserialize(\"$T_NODE_test_pivot_longer/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_pivot_longer = deserialize(\"$T_NODE_test_pivot_longer/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_single_cell/class\") && (read_file(\"$T_NODE_test_single_cell/class\") == \"VError\" || read_file(\"$T_NODE_test_single_cell/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_single_cell/class\") == \"Error\" || read_file(\"$T_NODE_test_single_cell/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_single_cell = deserialize(\"$T_NODE_test_single_cell/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_single_cell = deserialize(\"$T_NODE_test_single_cell/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_zero_cols/class\") && (read_file(\"$T_NODE_test_zero_cols/class\") == \"VError\" || read_file(\"$T_NODE_test_zero_cols/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_zero_cols/class\") == \"Error\" || read_file(\"$T_NODE_test_zero_cols/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_zero_cols = deserialize(\"$T_NODE_test_zero_cols/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_zero_cols = deserialize(\"$T_NODE_test_zero_cols/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
test_zero_cols = __dep_test_zero_cols
EOF
      cat <<'EOF' >> node_script.t
test_single_cell = __dep_test_single_cell
EOF
      cat <<'EOF' >> node_script.t
test_pivot_longer = __dep_test_pivot_longer
EOF
      cat <<'EOF' >> node_script.t
test_pivot_dup_keys = __dep_test_pivot_dup_keys
EOF
      cat <<'EOF' >> node_script.t
test_na_filter = __dep_test_na_filter
EOF
      cat <<'EOF' >> node_script.t
test_na_arithmetic = __dep_test_na_arithmetic
EOF
      cat <<'EOF' >> node_script.t
test_long_colname = __dep_test_long_colname
EOF
      cat <<'EOF' >> node_script.t
test_group_by_na = __dep_test_group_by_na
EOF
      cat <<'EOF' >> node_script.t
test_empty_grouped = __dep_test_empty_grouped
EOF
      cat <<'EOF' >> node_script.t
test_empty = __dep_test_empty
EOF
      cat <<'EOF' >> node_script.t
test_dup_colnames = __dep_test_dup_colnames
EOF
      cat <<'EOF' >> node_script.t
test_coerce_mutate = __dep_test_coerce_mutate
EOF
      cat <<'EOF' >> node_script.t
test_coerce_bind = __dep_test_coerce_bind
EOF
      cat <<'EOF' >> node_script.t
test_all_na = __dep_test_all_na
EOF

      cat <<'EOF' >> node_script.t
      __node_result = { results = [test_empty, test_all_na, test_single_cell, test_dup_colnames, test_long_colname, test_na_filter, test_na_arithmetic, test_coerce_mutate, test_coerce_bind, test_pivot_dup_keys, test_pivot_longer, test_group_by_na, test_empty_grouped, test_zero_cols]; failures = ((results |> to_dataframe) |> filter(($passed == false))); n_fail = nrow(failures); if ((n_fail > 0)) { print("FAILURES:"); print(failures); assert((n_fail == 0), str_sprintf("dataframe_abyss_t: %d tests failed", n_fail)) } else NA; [status: "ok", total: 14, passed: (14 - n_fail), failures: n_fail] }
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
    buildInputs = [ tBin test_empty test_all_na test_single_cell test_dup_colnames test_long_colname test_na_filter test_na_arithmetic test_coerce_mutate test_coerce_bind test_pivot_dup_keys test_pivot_longer test_group_by_na test_empty_grouped test_zero_cols validation projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${test_empty} $out/test_empty
      cp -r ${test_all_na} $out/test_all_na
      cp -r ${test_single_cell} $out/test_single_cell
      cp -r ${test_dup_colnames} $out/test_dup_colnames
      cp -r ${test_long_colname} $out/test_long_colname
      cp -r ${test_na_filter} $out/test_na_filter
      cp -r ${test_na_arithmetic} $out/test_na_arithmetic
      cp -r ${test_coerce_mutate} $out/test_coerce_mutate
      cp -r ${test_coerce_bind} $out/test_coerce_bind
      cp -r ${test_pivot_dup_keys} $out/test_pivot_dup_keys
      cp -r ${test_pivot_longer} $out/test_pivot_longer
      cp -r ${test_group_by_na} $out/test_group_by_na
      cp -r ${test_empty_grouped} $out/test_empty_grouped
      cp -r ${test_zero_cols} $out/test_zero_cols
      cp -r ${validation} $out/validation
    '';
  };
}

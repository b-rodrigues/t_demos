
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

  df = stdenv.mkDerivation {
    name = "df";
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
      __node_result = read_csv("src/mtcars.csv")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_csv(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_lm = stdenv.mkDerivation {
    name = "model_lm";
    buildInputs = [ tBin df ] ++ globalBuildInputs;
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

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_df/class\") && (read_file(\"$T_NODE_df/class\") == \"VError\" || read_file(\"$T_NODE_df/class\") == \"VError\\n\" || read_file(\"$T_NODE_df/class\") == \"Error\" || read_file(\"$T_NODE_df/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_df = deserialize(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_df = read_csv(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
df = __dep_df
EOF

      cat <<'EOF' >> node_script.t
      __node_result = lm((mpg ~ (wt + hp)), data = df)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_nested = stdenv.mkDerivation {
    name = "model_nested";
    buildInputs = [ tBin df ] ++ globalBuildInputs;
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

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_df/class\") && (read_file(\"$T_NODE_df/class\") == \"VError\" || read_file(\"$T_NODE_df/class\") == \"VError\\n\" || read_file(\"$T_NODE_df/class\") == \"Error\" || read_file(\"$T_NODE_df/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_df = deserialize(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_df = read_csv(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
df = __dep_df
EOF

      cat <<'EOF' >> node_script.t
      __node_result = lm((mpg ~ wt), data = df)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_summary = stdenv.mkDerivation {
    name = "node_summary";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = summary(model_lm)._tidy_df
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_coef = stdenv.mkDerivation {
    name = "node_coef";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = coef(model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_stats = stdenv.mkDerivation {
    name = "node_stats";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = fit_stats(model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_ci = stdenv.mkDerivation {
    name = "node_ci";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = conf_int(model_lm, 0.95)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_vcov = stdenv.mkDerivation {
    name = "node_vcov";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = vcov(model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_diag = stdenv.mkDerivation {
    name = "node_diag";
    buildInputs = [ tBin df model_lm ] ++ globalBuildInputs;
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
    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_df=${df}
      export T_INPUT_df=${df}/artifact
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_df/class\") && (read_file(\"$T_NODE_df/class\") == \"VError\" || read_file(\"$T_NODE_df/class\") == \"VError\\n\" || read_file(\"$T_NODE_df/class\") == \"Error\" || read_file(\"$T_NODE_df/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_df = deserialize(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_df = read_csv(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF
      cat <<'EOF' >> node_script.t
df = __dep_df
EOF

      cat <<'EOF' >> node_script.t
      __node_result = add_diagnostics(df, model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_resid = stdenv.mkDerivation {
    name = "node_resid";
    buildInputs = [ tBin df model_lm ] ++ globalBuildInputs;
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
    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_df=${df}
      export T_INPUT_df=${df}/artifact
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_df/class\") && (read_file(\"$T_NODE_df/class\") == \"VError\" || read_file(\"$T_NODE_df/class\") == \"VError\\n\" || read_file(\"$T_NODE_df/class\") == \"Error\" || read_file(\"$T_NODE_df/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_df = deserialize(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_df = read_csv(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF
      cat <<'EOF' >> node_script.t
df = __dep_df
EOF

      cat <<'EOF' >> node_script.t
      __node_result = residuals(df, model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_pred = stdenv.mkDerivation {
    name = "node_pred";
    buildInputs = [ tBin df model_lm ] ++ globalBuildInputs;
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
    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_df=${df}
      export T_INPUT_df=${df}/artifact
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_df/class\") && (read_file(\"$T_NODE_df/class\") == \"VError\" || read_file(\"$T_NODE_df/class\") == \"VError\\n\" || read_file(\"$T_NODE_df/class\") == \"Error\" || read_file(\"$T_NODE_df/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_df = deserialize(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_df = read_csv(\"$T_NODE_df/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF
      cat <<'EOF' >> node_script.t
df = __dep_df
EOF

      cat <<'EOF' >> node_script.t
      __node_result = predict(df, model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_compare = stdenv.mkDerivation {
    name = "node_compare";
    buildInputs = [ tBin model_lm model_nested ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    T_NODE_model_nested = model_nested;
    T_INPUT_model_nested = "${model_nested}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact
      export T_NODE_model_nested=${model_nested}
      export T_INPUT_model_nested=${model_nested}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_nested/class\") && (read_file(\"$T_NODE_model_nested/class\") == \"VError\" || read_file(\"$T_NODE_model_nested/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_nested/class\") == \"Error\" || read_file(\"$T_NODE_model_nested/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_nested = deserialize(\"$T_NODE_model_nested/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_nested = deserialize(\"$T_NODE_model_nested/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_nested = __dep_model_nested
EOF
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = compare(model_nested, model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_anova = stdenv.mkDerivation {
    name = "node_anova";
    buildInputs = [ tBin model_lm model_nested ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    T_NODE_model_nested = model_nested;
    T_INPUT_model_nested = "${model_nested}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact
      export T_NODE_model_nested=${model_nested}
      export T_INPUT_model_nested=${model_nested}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_nested/class\") && (read_file(\"$T_NODE_model_nested/class\") == \"VError\" || read_file(\"$T_NODE_model_nested/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_nested/class\") == \"Error\" || read_file(\"$T_NODE_model_nested/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_nested = deserialize(\"$T_NODE_model_nested/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_nested = deserialize(\"$T_NODE_model_nested/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_nested = __dep_model_nested
EOF
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = anova(model_nested, model_lm)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_wald = stdenv.mkDerivation {
    name = "node_wald";
    buildInputs = [ tBin model_lm ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_model_lm = model_lm;
    T_INPUT_model_lm = "${model_lm}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_model_lm=${model_lm}
      export T_INPUT_model_lm=${model_lm}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_model_lm/class\") && (read_file(\"$T_NODE_model_lm/class\") == \"VError\" || read_file(\"$T_NODE_model_lm/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\" || read_file(\"$T_NODE_model_lm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_lm = deserialize(\"$T_NODE_model_lm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
model_lm = __dep_model_lm
EOF

      cat <<'EOF' >> node_script.t
      __node_result = wald_test(model_lm, ["wt", "hp"])
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin df model_lm model_nested node_summary node_coef node_stats node_ci node_vcov node_diag node_resid node_pred node_compare node_anova node_wald projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${df} $out/df
      cp -r ${model_lm} $out/model_lm
      cp -r ${model_nested} $out/model_nested
      cp -r ${node_summary} $out/node_summary
      cp -r ${node_coef} $out/node_coef
      cp -r ${node_stats} $out/node_stats
      cp -r ${node_ci} $out/node_ci
      cp -r ${node_vcov} $out/node_vcov
      cp -r ${node_diag} $out/node_diag
      cp -r ${node_resid} $out/node_resid
      cp -r ${node_pred} $out/node_pred
      cp -r ${node_compare} $out/node_compare
      cp -r ${node_anova} $out/node_anova
      cp -r ${node_wald} $out/node_wald
    '';
  };
}

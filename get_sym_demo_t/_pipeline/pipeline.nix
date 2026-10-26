
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

  my_var = stdenv.mkDerivation {
    name = "my_var";
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
      __node_result = 42
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  var_name = stdenv.mkDerivation {
    name = "var_name";
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
      __node_result = "my_var"
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val1 = stdenv.mkDerivation {
    name = "val1";
    buildInputs = [ tBin my_var ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_my_var = my_var;
    T_INPUT_my_var = "${my_var}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_var=${my_var}
      export T_INPUT_my_var=${my_var}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_my_var/class\") && (read_file(\"$T_NODE_my_var/class\") == \"VError\" || read_file(\"$T_NODE_my_var/class\") == \"VError\\n\" || read_file(\"$T_NODE_my_var/class\") == \"Error\" || read_file(\"$T_NODE_my_var/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
my_var = __dep_my_var
EOF

      cat <<'EOF' >> node_script.t
      __node_result = get("my_var")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val1 = stdenv.mkDerivation {
    name = "test_val1";
    buildInputs = [ tBin val1 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_val1 = val1;
    T_INPUT_val1 = "${val1}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val1=${val1}
      export T_INPUT_val1=${val1}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_val1/class\") && (read_file(\"$T_NODE_val1/class\") == \"VError\" || read_file(\"$T_NODE_val1/class\") == \"VError\\n\" || read_file(\"$T_NODE_val1/class\") == \"Error\" || read_file(\"$T_NODE_val1/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_val1 = deserialize(\"$T_NODE_val1/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_val1 = deserialize(\"$T_NODE_val1/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
val1 = __dep_val1
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((val1 == 42))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val2 = stdenv.mkDerivation {
    name = "val2";
    buildInputs = [ tBin my_var var_name ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_my_var = my_var;
    T_INPUT_my_var = "${my_var}/artifact";
    T_NODE_var_name = var_name;
    T_INPUT_var_name = "${var_name}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_var=${my_var}
      export T_INPUT_my_var=${my_var}/artifact
      export T_NODE_var_name=${var_name}
      export T_INPUT_var_name=${var_name}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_my_var/class\") && (read_file(\"$T_NODE_my_var/class\") == \"VError\" || read_file(\"$T_NODE_my_var/class\") == \"VError\\n\" || read_file(\"$T_NODE_my_var/class\") == \"Error\" || read_file(\"$T_NODE_my_var/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_var_name/class\") && (read_file(\"$T_NODE_var_name/class\") == \"VError\" || read_file(\"$T_NODE_var_name/class\") == \"VError\\n\" || read_file(\"$T_NODE_var_name/class\") == \"Error\" || read_file(\"$T_NODE_var_name/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_var_name = deserialize(\"$T_NODE_var_name/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_var_name = deserialize(\"$T_NODE_var_name/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
var_name = __dep_var_name
EOF
      cat <<'EOF' >> node_script.t
my_var = __dep_my_var
EOF

      cat <<'EOF' >> node_script.t
      __node_result = get(to_symbol(var_name))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val2 = stdenv.mkDerivation {
    name = "test_val2";
    buildInputs = [ tBin val2 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_val2 = val2;
    T_INPUT_val2 = "${val2}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val2=${val2}
      export T_INPUT_val2=${val2}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_val2/class\") && (read_file(\"$T_NODE_val2/class\") == \"VError\" || read_file(\"$T_NODE_val2/class\") == \"VError\\n\" || read_file(\"$T_NODE_val2/class\") == \"Error\" || read_file(\"$T_NODE_val2/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_val2 = deserialize(\"$T_NODE_val2/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_val2 = deserialize(\"$T_NODE_val2/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
val2 = __dep_val2
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((val2 == 42))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  my_list = stdenv.mkDerivation {
    name = "my_list";
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
      __node_result = [10, 20, 30, 40]
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val3 = stdenv.mkDerivation {
    name = "val3";
    buildInputs = [ tBin my_list ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_my_list = my_list;
    T_INPUT_my_list = "${my_list}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_list=${my_list}
      export T_INPUT_my_list=${my_list}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_my_list/class\") && (read_file(\"$T_NODE_my_list/class\") == \"VError\" || read_file(\"$T_NODE_my_list/class\") == \"VError\\n\" || read_file(\"$T_NODE_my_list/class\") == \"Error\" || read_file(\"$T_NODE_my_list/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_my_list = deserialize(\"$T_NODE_my_list/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_my_list = deserialize(\"$T_NODE_my_list/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
my_list = __dep_my_list
EOF

      cat <<'EOF' >> node_script.t
      __node_result = get(my_list, 2)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val3 = stdenv.mkDerivation {
    name = "test_val3";
    buildInputs = [ tBin val3 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_val3 = val3;
    T_INPUT_val3 = "${val3}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val3=${val3}
      export T_INPUT_val3=${val3}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_val3/class\") && (read_file(\"$T_NODE_val3/class\") == \"VError\" || read_file(\"$T_NODE_val3/class\") == \"VError\\n\" || read_file(\"$T_NODE_val3/class\") == \"Error\" || read_file(\"$T_NODE_val3/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_val3 = deserialize(\"$T_NODE_val3/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_val3 = deserialize(\"$T_NODE_val3/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
val3 = __dep_val3
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((val3 == 30))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_a = stdenv.mkDerivation {
    name = "node_a";
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
      __node_result = 100
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_b = stdenv.mkDerivation {
    name = "node_b";
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
      __node_result = 200
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  dynamic_access = stdenv.mkDerivation {
    name = "dynamic_access";
    buildInputs = [ tBin node_a node_b ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_node_a = node_a;
    T_INPUT_node_a = "${node_a}/artifact";
    T_NODE_node_b = node_b;
    T_INPUT_node_b = "${node_b}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_node_a=${node_a}
      export T_INPUT_node_a=${node_a}/artifact
      export T_NODE_node_b=${node_b}
      export T_INPUT_node_b=${node_b}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_node_a/class\") && (read_file(\"$T_NODE_node_a/class\") == \"VError\" || read_file(\"$T_NODE_node_a/class\") == \"VError\\n\" || read_file(\"$T_NODE_node_a/class\") == \"Error\" || read_file(\"$T_NODE_node_a/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_node_a = deserialize(\"$T_NODE_node_a/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_node_a = t_read_json(\"$T_NODE_node_a/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_node_b/class\") && (read_file(\"$T_NODE_node_b/class\") == \"VError\" || read_file(\"$T_NODE_node_b/class\") == \"VError\\n\" || read_file(\"$T_NODE_node_b/class\") == \"Error\" || read_file(\"$T_NODE_node_b/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_node_b = deserialize(\"$T_NODE_node_b/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_node_b = t_read_json(\"$T_NODE_node_b/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
node_b = __dep_node_b
EOF
      cat <<'EOF' >> node_script.t
node_a = __dep_node_a
EOF

      cat <<'EOF' >> node_script.t
      __node_result = { target = "node_a"; get(node_lens(target)) }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_dynamic = stdenv.mkDerivation {
    name = "test_dynamic";
    buildInputs = [ tBin dynamic_access ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_dynamic_access = dynamic_access;
    T_INPUT_dynamic_access = "${dynamic_access}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_dynamic_access=${dynamic_access}
      export T_INPUT_dynamic_access=${dynamic_access}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_dynamic_access/class\") && (read_file(\"$T_NODE_dynamic_access/class\") == \"VError\" || read_file(\"$T_NODE_dynamic_access/class\") == \"VError\\n\" || read_file(\"$T_NODE_dynamic_access/class\") == \"Error\" || read_file(\"$T_NODE_dynamic_access/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_dynamic_access = deserialize(\"$T_NODE_dynamic_access/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_dynamic_access = deserialize(\"$T_NODE_dynamic_access/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
dynamic_access = __dep_dynamic_access
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((dynamic_access == 100))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  target_col = stdenv.mkDerivation {
    name = "target_col";
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
      __node_result = "mpg"
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  s = stdenv.mkDerivation {
    name = "s";
    buildInputs = [ tBin target_col ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_target_col = target_col;
    T_INPUT_target_col = "${target_col}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_target_col=${target_col}
      export T_INPUT_target_col=${target_col}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_target_col/class\") && (read_file(\"$T_NODE_target_col/class\") == \"VError\" || read_file(\"$T_NODE_target_col/class\") == \"VError\\n\" || read_file(\"$T_NODE_target_col/class\") == \"Error\" || read_file(\"$T_NODE_target_col/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_target_col = deserialize(\"$T_NODE_target_col/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_target_col = deserialize(\"$T_NODE_target_col/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
target_col = __dep_target_col
EOF

      cat <<'EOF' >> node_script.t
      __node_result = to_symbol(target_col)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_sym = stdenv.mkDerivation {
    name = "test_sym";
    buildInputs = [ tBin s ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_s = s;
    T_INPUT_s = "${s}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_s=${s}
      export T_INPUT_s=${s}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_s/class\") && (read_file(\"$T_NODE_s/class\") == \"VError\" || read_file(\"$T_NODE_s/class\") == \"VError\\n\" || read_file(\"$T_NODE_s/class\") == \"Error\" || read_file(\"$T_NODE_s/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_s = deserialize(\"$T_NODE_s/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_s = deserialize(\"$T_NODE_s/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
s = __dep_s
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((type(s) == "Symbol"))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  my_dict = stdenv.mkDerivation {
    name = "my_dict";
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
      __node_result = [a: 1, b: 2]
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  l = stdenv.mkDerivation {
    name = "l";
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
      __node_result = col_lens("b")
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val4 = stdenv.mkDerivation {
    name = "val4";
    buildInputs = [ tBin l my_dict ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_l = l;
    T_INPUT_l = "${l}/artifact";
    T_NODE_my_dict = my_dict;
    T_INPUT_my_dict = "${my_dict}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_l=${l}
      export T_INPUT_l=${l}/artifact
      export T_NODE_my_dict=${my_dict}
      export T_INPUT_my_dict=${my_dict}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_l/class\") && (read_file(\"$T_NODE_l/class\") == \"VError\" || read_file(\"$T_NODE_l/class\") == \"VError\\n\" || read_file(\"$T_NODE_l/class\") == \"Error\" || read_file(\"$T_NODE_l/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_l = deserialize(\"$T_NODE_l/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_l = deserialize(\"$T_NODE_l/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_my_dict/class\") && (read_file(\"$T_NODE_my_dict/class\") == \"VError\" || read_file(\"$T_NODE_my_dict/class\") == \"VError\\n\" || read_file(\"$T_NODE_my_dict/class\") == \"Error\" || read_file(\"$T_NODE_my_dict/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_my_dict = deserialize(\"$T_NODE_my_dict/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_my_dict = deserialize(\"$T_NODE_my_dict/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
my_dict = __dep_my_dict
EOF
      cat <<'EOF' >> node_script.t
l = __dep_l
EOF

      cat <<'EOF' >> node_script.t
      __node_result = get(my_dict, l)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val4 = stdenv.mkDerivation {
    name = "test_val4";
    buildInputs = [ tBin val4 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_val4 = val4;
    T_INPUT_val4 = "${val4}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val4=${val4}
      export T_INPUT_val4=${val4}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_val4/class\") && (read_file(\"$T_NODE_val4/class\") == \"VError\" || read_file(\"$T_NODE_val4/class\") == \"VError\\n\" || read_file(\"$T_NODE_val4/class\") == \"Error\" || read_file(\"$T_NODE_val4/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_val4 = deserialize(\"$T_NODE_val4/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_val4 = deserialize(\"$T_NODE_val4/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
val4 = __dep_val4
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((val4 == 2))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  all_passed = stdenv.mkDerivation {
    name = "all_passed";
    buildInputs = [ tBin test_dynamic test_sym test_val1 test_val2 test_val3 test_val4 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_test_dynamic = test_dynamic;
    T_INPUT_test_dynamic = "${test_dynamic}/artifact";
    T_NODE_test_sym = test_sym;
    T_INPUT_test_sym = "${test_sym}/artifact";
    T_NODE_test_val1 = test_val1;
    T_INPUT_test_val1 = "${test_val1}/artifact";
    T_NODE_test_val2 = test_val2;
    T_INPUT_test_val2 = "${test_val2}/artifact";
    T_NODE_test_val3 = test_val3;
    T_INPUT_test_val3 = "${test_val3}/artifact";
    T_NODE_test_val4 = test_val4;
    T_INPUT_test_val4 = "${test_val4}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_test_dynamic=${test_dynamic}
      export T_INPUT_test_dynamic=${test_dynamic}/artifact
      export T_NODE_test_sym=${test_sym}
      export T_INPUT_test_sym=${test_sym}/artifact
      export T_NODE_test_val1=${test_val1}
      export T_INPUT_test_val1=${test_val1}/artifact
      export T_NODE_test_val2=${test_val2}
      export T_INPUT_test_val2=${test_val2}/artifact
      export T_NODE_test_val3=${test_val3}
      export T_INPUT_test_val3=${test_val3}/artifact
      export T_NODE_test_val4=${test_val4}
      export T_INPUT_test_val4=${test_val4}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_test_dynamic/class\") && (read_file(\"$T_NODE_test_dynamic/class\") == \"VError\" || read_file(\"$T_NODE_test_dynamic/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_dynamic/class\") == \"Error\" || read_file(\"$T_NODE_test_dynamic/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_dynamic = deserialize(\"$T_NODE_test_dynamic/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_dynamic = deserialize(\"$T_NODE_test_dynamic/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_sym/class\") && (read_file(\"$T_NODE_test_sym/class\") == \"VError\" || read_file(\"$T_NODE_test_sym/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_sym/class\") == \"Error\" || read_file(\"$T_NODE_test_sym/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_sym = deserialize(\"$T_NODE_test_sym/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_sym = deserialize(\"$T_NODE_test_sym/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_val1/class\") && (read_file(\"$T_NODE_test_val1/class\") == \"VError\" || read_file(\"$T_NODE_test_val1/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_val1/class\") == \"Error\" || read_file(\"$T_NODE_test_val1/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_val1 = deserialize(\"$T_NODE_test_val1/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_val1 = deserialize(\"$T_NODE_test_val1/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_val2/class\") && (read_file(\"$T_NODE_test_val2/class\") == \"VError\" || read_file(\"$T_NODE_test_val2/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_val2/class\") == \"Error\" || read_file(\"$T_NODE_test_val2/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_val2 = deserialize(\"$T_NODE_test_val2/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_val2 = deserialize(\"$T_NODE_test_val2/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_val3/class\") && (read_file(\"$T_NODE_test_val3/class\") == \"VError\" || read_file(\"$T_NODE_test_val3/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_val3/class\") == \"Error\" || read_file(\"$T_NODE_test_val3/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_val3 = deserialize(\"$T_NODE_test_val3/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_val3 = deserialize(\"$T_NODE_test_val3/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_val4/class\") && (read_file(\"$T_NODE_test_val4/class\") == \"VError\" || read_file(\"$T_NODE_test_val4/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_val4/class\") == \"Error\" || read_file(\"$T_NODE_test_val4/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_val4 = deserialize(\"$T_NODE_test_val4/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_val4 = deserialize(\"$T_NODE_test_val4/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
test_val4 = __dep_test_val4
EOF
      cat <<'EOF' >> node_script.t
test_val3 = __dep_test_val3
EOF
      cat <<'EOF' >> node_script.t
test_val2 = __dep_test_val2
EOF
      cat <<'EOF' >> node_script.t
test_val1 = __dep_test_val1
EOF
      cat <<'EOF' >> node_script.t
test_sym = __dep_test_sym
EOF
      cat <<'EOF' >> node_script.t
test_dynamic = __dep_test_dynamic
EOF

      cat <<'EOF' >> node_script.t
      __node_result = assert((((((test_val1 && test_val2) && test_val3) && test_dynamic) && test_sym) && test_val4))
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
    buildInputs = [ tBin my_var var_name val1 test_val1 val2 test_val2 my_list val3 test_val3 node_a node_b dynamic_access test_dynamic target_col s test_sym my_dict l val4 test_val4 all_passed projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${my_var} $out/my_var
      cp -r ${var_name} $out/var_name
      cp -r ${val1} $out/val1
      cp -r ${test_val1} $out/test_val1
      cp -r ${val2} $out/val2
      cp -r ${test_val2} $out/test_val2
      cp -r ${my_list} $out/my_list
      cp -r ${val3} $out/val3
      cp -r ${test_val3} $out/test_val3
      cp -r ${node_a} $out/node_a
      cp -r ${node_b} $out/node_b
      cp -r ${dynamic_access} $out/dynamic_access
      cp -r ${test_dynamic} $out/test_dynamic
      cp -r ${target_col} $out/target_col
      cp -r ${s} $out/s
      cp -r ${test_sym} $out/test_sym
      cp -r ${my_dict} $out/my_dict
      cp -r ${l} $out/l
      cp -r ${val4} $out/val4
      cp -r ${test_val4} $out/test_val4
      cp -r ${all_passed} $out/all_passed
    '';
  };
}

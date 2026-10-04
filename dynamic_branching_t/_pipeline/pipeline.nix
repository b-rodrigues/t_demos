
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

  fixed_radii = stdenv.mkDerivation {
    name = "fixed_radii";
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









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = [3, 5, 8]
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  cycling_radii = stdenv.mkDerivation {
    name = "cycling_radii";
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









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t




      cat <<'EOF' >> node_script.t
      __node_result = [2, 4, 6]
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_1 = stdenv.mkDerivation {
    name = "points_branch_1";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(3, 2)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_2 = stdenv.mkDerivation {
    name = "points_branch_2";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(3, 4)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_3 = stdenv.mkDerivation {
    name = "points_branch_3";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(3, 6)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_4 = stdenv.mkDerivation {
    name = "points_branch_4";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(5, 2)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_5 = stdenv.mkDerivation {
    name = "points_branch_5";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(5, 4)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_6 = stdenv.mkDerivation {
    name = "points_branch_6";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(5, 6)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_7 = stdenv.mkDerivation {
    name = "points_branch_7";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(8, 2)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_8 = stdenv.mkDerivation {
    name = "points_branch_8";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(8, 4)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  points_branch_9 = stdenv.mkDerivation {
    name = "points_branch_9";
    buildInputs = [ tBin cycling_radii fixed_radii ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_cycling_radii = cycling_radii;
    T_INPUT_cycling_radii = "${cycling_radii}/artifact";
    T_NODE_fixed_radii = fixed_radii;
    T_INPUT_fixed_radii = "${fixed_radii}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_cycling_radii=${cycling_radii}
      export T_INPUT_cycling_radii=${cycling_radii}/artifact
      export T_NODE_fixed_radii=${fixed_radii}
      export T_INPUT_fixed_radii=${fixed_radii}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import strcraft' >> node_script.t
      echo 'import colcraft' >> node_script.t


      echo "if (file_exists(\"$T_NODE_cycling_radii/class\") && (read_file(\"$T_NODE_cycling_radii/class\") == \"VError\" || read_file(\"$T_NODE_cycling_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\" || read_file(\"$T_NODE_cycling_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_cycling_radii = deserialize(\"$T_NODE_cycling_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_fixed_radii/class\") && (read_file(\"$T_NODE_fixed_radii/class\") == \"VError\" || read_file(\"$T_NODE_fixed_radii/class\") == \"VError\\n\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\" || read_file(\"$T_NODE_fixed_radii/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_fixed_radii = deserialize(\"$T_NODE_fixed_radii/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
fixed_radii = __dep_fixed_radii
EOF
      cat <<'EOF' >> node_script.t
cycling_radii = __dep_cycling_radii
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
import "src/spirograph.t"
      spirograph_points(8, 6)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = t_write_json(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  single_plot_branch_1 = stdenv.mkDerivation {
    name = "single_plot_branch_1";
    buildInputs = [ tBin r-env points_branch_1 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_1 = points_branch_1;
    T_INPUT_points_branch_1 = "${points_branch_1}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_1=${points_branch_1}
      export T_INPUT_points_branch_1=${points_branch_1}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_1\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_1\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_1 <- r_read_json(file.path(\"$T_NODE_points_branch_1\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_1 <- r_read_json(file.path(\"$T_NODE_points_branch_1\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_1 <- dep_points_branch_1" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_1)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_2 = stdenv.mkDerivation {
    name = "single_plot_branch_2";
    buildInputs = [ tBin r-env points_branch_2 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_2 = points_branch_2;
    T_INPUT_points_branch_2 = "${points_branch_2}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_2=${points_branch_2}
      export T_INPUT_points_branch_2=${points_branch_2}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_2\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_2\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_2 <- r_read_json(file.path(\"$T_NODE_points_branch_2\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_2 <- r_read_json(file.path(\"$T_NODE_points_branch_2\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_2 <- dep_points_branch_2" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_2)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_3 = stdenv.mkDerivation {
    name = "single_plot_branch_3";
    buildInputs = [ tBin r-env points_branch_3 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_3 = points_branch_3;
    T_INPUT_points_branch_3 = "${points_branch_3}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_3=${points_branch_3}
      export T_INPUT_points_branch_3=${points_branch_3}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_3\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_3\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_3 <- r_read_json(file.path(\"$T_NODE_points_branch_3\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_3 <- r_read_json(file.path(\"$T_NODE_points_branch_3\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_3 <- dep_points_branch_3" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_3)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_4 = stdenv.mkDerivation {
    name = "single_plot_branch_4";
    buildInputs = [ tBin r-env points_branch_4 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_4 = points_branch_4;
    T_INPUT_points_branch_4 = "${points_branch_4}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_4=${points_branch_4}
      export T_INPUT_points_branch_4=${points_branch_4}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_4\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_4\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_4 <- r_read_json(file.path(\"$T_NODE_points_branch_4\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_4 <- r_read_json(file.path(\"$T_NODE_points_branch_4\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_4 <- dep_points_branch_4" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_4)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_5 = stdenv.mkDerivation {
    name = "single_plot_branch_5";
    buildInputs = [ tBin r-env points_branch_5 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_5 = points_branch_5;
    T_INPUT_points_branch_5 = "${points_branch_5}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_5=${points_branch_5}
      export T_INPUT_points_branch_5=${points_branch_5}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_5\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_5\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_5 <- r_read_json(file.path(\"$T_NODE_points_branch_5\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_5 <- r_read_json(file.path(\"$T_NODE_points_branch_5\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_5 <- dep_points_branch_5" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_5)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_6 = stdenv.mkDerivation {
    name = "single_plot_branch_6";
    buildInputs = [ tBin r-env points_branch_6 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_6 = points_branch_6;
    T_INPUT_points_branch_6 = "${points_branch_6}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_6=${points_branch_6}
      export T_INPUT_points_branch_6=${points_branch_6}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_6\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_6\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_6 <- r_read_json(file.path(\"$T_NODE_points_branch_6\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_6 <- r_read_json(file.path(\"$T_NODE_points_branch_6\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_6 <- dep_points_branch_6" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_6)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_7 = stdenv.mkDerivation {
    name = "single_plot_branch_7";
    buildInputs = [ tBin r-env points_branch_7 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_7 = points_branch_7;
    T_INPUT_points_branch_7 = "${points_branch_7}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_7=${points_branch_7}
      export T_INPUT_points_branch_7=${points_branch_7}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_7\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_7\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_7 <- r_read_json(file.path(\"$T_NODE_points_branch_7\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_7 <- r_read_json(file.path(\"$T_NODE_points_branch_7\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_7 <- dep_points_branch_7" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_7)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_8 = stdenv.mkDerivation {
    name = "single_plot_branch_8";
    buildInputs = [ tBin r-env points_branch_8 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_8 = points_branch_8;
    T_INPUT_points_branch_8 = "${points_branch_8}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_8=${points_branch_8}
      export T_INPUT_points_branch_8=${points_branch_8}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_8\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_8\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_8 <- r_read_json(file.path(\"$T_NODE_points_branch_8\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_8 <- r_read_json(file.path(\"$T_NODE_points_branch_8\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_8 <- dep_points_branch_8" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_8)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
EOF
       echo "  writeLines(r_visual_class(node_result), file.path(Sys.getenv('out'), 'class'))" >> node_script.R
       echo "  r_write_warnings(captured_warns, file.path(Sys.getenv('out'), 'warnings'))" >> node_script.R
       echo "}" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };
 

  single_plot_branch_9 = stdenv.mkDerivation {
    name = "single_plot_branch_9";
    buildInputs = [ tBin r-env points_branch_9 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_points_branch_9 = points_branch_9;
    T_INPUT_points_branch_9 = "${points_branch_9}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_points_branch_9=${points_branch_9}
      export T_INPUT_points_branch_9=${points_branch_9}/artifact

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







      echo "source('src/spirograph.R')" >> node_script.R

      echo "if (file.exists(file.path(\"$T_NODE_points_branch_9\", \"class\")) && readLines(file.path(\"$T_NODE_points_branch_9\", \"class\"), 1) == \"VError\") {" >> node_script.R
      echo "  dep_points_branch_9 <- r_read_json(file.path(\"$T_NODE_points_branch_9\", \"artifact\"))" >> node_script.R
      echo "} else {" >> node_script.R
      echo "  dep_points_branch_9 <- r_read_json(file.path(\"$T_NODE_points_branch_9\", \"artifact\"))" >> node_script.R
      echo "}" >> node_script.R
      echo "points_branch_9 <- dep_points_branch_9" >> node_script.R

      echo "captured_warns <- list()" >> node_script.R
      echo "node_result <- withCallingHandlers({" >> node_script.R
      echo "  local({" >> node_script.R
      echo "    tryCatch({" >> node_script.R
      cat <<'EOF' >> node_script.R
plot_spirographs(points_branch_9)
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
  r_save_viz_metadata(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}viz${"'"}))
  saveRDS(node_result, file.path(Sys.getenv(${"'"}out${"'"}), ${"'"}artifact${"'"}))
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
    buildInputs = [ tBin fixed_radii cycling_radii points_branch_1 points_branch_2 points_branch_3 points_branch_4 points_branch_5 points_branch_6 points_branch_7 points_branch_8 points_branch_9 single_plot_branch_1 single_plot_branch_2 single_plot_branch_3 single_plot_branch_4 single_plot_branch_5 single_plot_branch_6 single_plot_branch_7 single_plot_branch_8 single_plot_branch_9 projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${fixed_radii} $out/fixed_radii
      cp -r ${cycling_radii} $out/cycling_radii
      cp -r ${points_branch_1} $out/points_branch_1
      cp -r ${points_branch_2} $out/points_branch_2
      cp -r ${points_branch_3} $out/points_branch_3
      cp -r ${points_branch_4} $out/points_branch_4
      cp -r ${points_branch_5} $out/points_branch_5
      cp -r ${points_branch_6} $out/points_branch_6
      cp -r ${points_branch_7} $out/points_branch_7
      cp -r ${points_branch_8} $out/points_branch_8
      cp -r ${points_branch_9} $out/points_branch_9
      cp -r ${single_plot_branch_1} $out/single_plot_branch_1
      cp -r ${single_plot_branch_2} $out/single_plot_branch_2
      cp -r ${single_plot_branch_3} $out/single_plot_branch_3
      cp -r ${single_plot_branch_4} $out/single_plot_branch_4
      cp -r ${single_plot_branch_5} $out/single_plot_branch_5
      cp -r ${single_plot_branch_6} $out/single_plot_branch_6
      cp -r ${single_plot_branch_7} $out/single_plot_branch_7
      cp -r ${single_plot_branch_8} $out/single_plot_branch_8
      cp -r ${single_plot_branch_9} $out/single_plot_branch_9
    '';
  };
}

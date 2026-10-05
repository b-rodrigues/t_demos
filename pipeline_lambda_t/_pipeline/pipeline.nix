
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

  raw = stdenv.mkDerivation {
    name = "raw";
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
      __node_result = 10
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  computed = stdenv.mkDerivation {
    name = "computed";
    buildInputs = [ tBin raw ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_raw = raw;
    T_INPUT_raw = "${raw}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw=${raw}
      export T_INPUT_raw=${raw}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_raw/class\") && (read_file(\"$T_NODE_raw/class\") == \"VError\" || read_file(\"$T_NODE_raw/class\") == \"VError\\n\" || read_file(\"$T_NODE_raw/class\") == \"Error\" || read_file(\"$T_NODE_raw/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_raw = deserialize(\"$T_NODE_raw/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_raw = deserialize(\"$T_NODE_raw/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
raw = __dep_raw
EOF

      cat <<'EOF' >> node_script.t
      __node_result = (raw * 5)
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
    buildInputs = [ tBin raw computed projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw} $out/raw
      cp -r ${computed} $out/computed
    '';
  };
}

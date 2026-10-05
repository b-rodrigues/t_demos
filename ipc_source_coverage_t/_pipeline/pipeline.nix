
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

  source_csv = stdenv.mkDerivation {
    name = "source_csv";
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









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t




      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
seed = to_dataframe([
                [id: 1, team: "alpha", amount: 10.0, offset: 2.0, bonus: 1.5, flag: true, note: "alpha,beta", stage: "low"],
                [id: 2, team: "alpha", amount: 14.0, offset: 3.5, bonus: 2.0, flag: false, note: "plain text", stage: "medium"],
                [id: 3, team: "beta", amount: 18.0, offset: 4.0, bonus: na_float(), flag: true, note: "beta,gamma", stage: "high"],
                [id: 4, team: "beta", amount: 22.0, offset: 5.0, bonus: 3.5, flag: true, note: "delta,epsilon", stage: "medium"],
                [id: 5, team: "gamma", amount: 26.0, offset: 6.5, bonus: 4.5, flag: false, note: na_string(), stage: "high"],
                [id: 6, team: "gamma", amount: 30.0, offset: 7.0, bonus: 5.0, flag: true, note: "final,row", stage: "low"]
            ])
            print("Seed type:")
            print(type(seed))
            csv_path = "ipc_source_coverage_seed.csv"
            res_w = write_csv(seed, csv_path)
            print("Write result:")
            print(res_w)
            read_csv(csv_path)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  ipc_roundtrip = stdenv.mkDerivation {
    name = "ipc_roundtrip";
    buildInputs = [ tBin source_csv ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_source_csv = source_csv;
    T_INPUT_source_csv = "${source_csv}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_source_csv=${source_csv}
      export T_INPUT_source_csv=${source_csv}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_source_csv/class\") && (read_file(\"$T_NODE_source_csv/class\") == \"VError\" || read_file(\"$T_NODE_source_csv/class\") == \"VError\\n\" || read_file(\"$T_NODE_source_csv/class\") == \"Error\" || read_file(\"$T_NODE_source_csv/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_source_csv = deserialize(\"$T_NODE_source_csv/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_source_csv = read_ipc(\"$T_NODE_source_csv/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
source_csv = __dep_source_csv
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
ipc_path = "ipc_source_coverage.arrow"
            write_ipc(source_csv, ipc_path)
            read_ipc(ipc_path)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  compute_features = stdenv.mkDerivation {
    name = "compute_features";
    buildInputs = [ tBin ipc_roundtrip ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_ipc_roundtrip = ipc_roundtrip;
    T_INPUT_ipc_roundtrip = "${ipc_roundtrip}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_ipc_roundtrip=${ipc_roundtrip}
      export T_INPUT_ipc_roundtrip=${ipc_roundtrip}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_ipc_roundtrip/class\") && (read_file(\"$T_NODE_ipc_roundtrip/class\") == \"VError\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"VError\\n\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"Error\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_ipc_roundtrip = deserialize(\"$T_NODE_ipc_roundtrip/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_ipc_roundtrip = read_ipc(\"$T_NODE_ipc_roundtrip/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
ipc_roundtrip = __dep_ipc_roundtrip
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
ipc_roundtrip
                |> mutate(
                    $stage = to_factor($stage, levels = ["low", "medium", "high"], ordered = true),
                    $net = $amount - $offset,
                    $gap = abs($amount - 18.0),
                    $log_amount = log($amount),
                    $sqrt_amount = sqrt($amount),
                    $amount_sq = pow($amount, 2.0),
                    $exp_offset = exp($offset / 10.0),
                    $row_id = row_number($amount),
                    $min_rank = min_rank($amount),
                    $dense = dense_rank($amount),
                    $pct_rank = percent_rank($amount),
                    $cume = cume_dist($amount),
                    $prev_amount = lag($amount),
                    $prev_two = lag($amount, 2),
                    $next_amount = lead($amount),
                    $next_two = lead($amount, 2),
                    $running_amount = cumsum($amount)
                )
                |> relocate($note, .before = $team)
                |> rename(segment = $team)
                |> arrange($amount)
                |> distinct()
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  top_slice = stdenv.mkDerivation {
    name = "top_slice";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = ((compute_features |> arrange($amount, direction = "desc")) |> slice([0, 1, 2]))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  active_projection = stdenv.mkDerivation {
    name = "active_projection";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = ((compute_features |> filter($flag)) |> select($id, $segment, $amount, $net, $stage))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  segment_counts = stdenv.mkDerivation {
    name = "segment_counts";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = count(compute_features, $segment)
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  grouped_summary = stdenv.mkDerivation {
    name = "grouped_summary";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = ((((compute_features |> mutate(stage_s = to_string($stage))) |> group_by($segment)) |> summarize(avg_amount = mean($amount), min_amount = min($amount), max_amount = max($amount), unique_stages = n_distinct($stage_s), total_bonus = sum($bonus, na_rm = true), last_running = max($running_amount))) |> arrange($segment))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  aggregate_snapshot = stdenv.mkDerivation {
    name = "aggregate_snapshot";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = (compute_features |> summarize(min_amount = min($amount), max_amount = max($amount), unique_segments = n_distinct($segment), avg_exp_offset = mean($exp_offset)))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  nested_groups = stdenv.mkDerivation {
    name = "nested_groups";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      cat <<'EOF' >> node_script.t
      __node_result = ((compute_features |> group_by($segment)) |> nest())
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  roundtrip_nested = stdenv.mkDerivation {
    name = "roundtrip_nested";
    buildInputs = [ tBin nested_groups ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_nested_groups = nested_groups;
    T_INPUT_nested_groups = "${nested_groups}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_nested_groups=${nested_groups}
      export T_INPUT_nested_groups=${nested_groups}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_nested_groups/class\") && (read_file(\"$T_NODE_nested_groups/class\") == \"VError\" || read_file(\"$T_NODE_nested_groups/class\") == \"VError\\n\" || read_file(\"$T_NODE_nested_groups/class\") == \"Error\" || read_file(\"$T_NODE_nested_groups/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_nested_groups = deserialize(\"$T_NODE_nested_groups/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_nested_groups = deserialize(\"$T_NODE_nested_groups/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
nested_groups = __dep_nested_groups
EOF

      cat <<'EOF' >> node_script.t
      __node_result = ((nested_groups |> unnest($data)) |> arrange($id))
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_diagnostics = stdenv.mkDerivation {
    name = "model_diagnostics";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(model, data = compute_features)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_predictions = stdenv.mkDerivation {
    name = "model_predictions";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            predict(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_augmented = stdenv.mkDerivation {
    name = "model_augmented";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_residuals = stdenv.mkDerivation {
    name = "model_residuals";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            residuals(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_coefficients = stdenv.mkDerivation {
    name = "model_coefficients";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            coef(model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_confidence = stdenv.mkDerivation {
    name = "model_confidence";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            conf_int(model)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_fit_stats = stdenv.mkDerivation {
    name = "model_fit_stats";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            fit_stats([reduced: reduced, full: full])
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_anova = stdenv.mkDerivation {
    name = "model_anova";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            anova(reduced, full)
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = write_ipc(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  model_wald = stdenv.mkDerivation {
    name = "model_wald";
    buildInputs = [ tBin compute_features ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            wald_test(model, terms = ["offset"])
EOF
      echo "      }" >> node_script.t
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validation_report = stdenv.mkDerivation {
    name = "validation_report";
    buildInputs = [ tBin active_projection aggregate_snapshot compute_features grouped_summary ipc_roundtrip model_anova model_augmented model_coefficients model_confidence model_diagnostics model_fit_stats model_predictions model_residuals model_wald roundtrip_nested segment_counts source_csv top_slice ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_active_projection = active_projection;
    T_INPUT_active_projection = "${active_projection}/artifact";
    T_NODE_aggregate_snapshot = aggregate_snapshot;
    T_INPUT_aggregate_snapshot = "${aggregate_snapshot}/artifact";
    T_NODE_compute_features = compute_features;
    T_INPUT_compute_features = "${compute_features}/artifact";
    T_NODE_grouped_summary = grouped_summary;
    T_INPUT_grouped_summary = "${grouped_summary}/artifact";
    T_NODE_ipc_roundtrip = ipc_roundtrip;
    T_INPUT_ipc_roundtrip = "${ipc_roundtrip}/artifact";
    T_NODE_model_anova = model_anova;
    T_INPUT_model_anova = "${model_anova}/artifact";
    T_NODE_model_augmented = model_augmented;
    T_INPUT_model_augmented = "${model_augmented}/artifact";
    T_NODE_model_coefficients = model_coefficients;
    T_INPUT_model_coefficients = "${model_coefficients}/artifact";
    T_NODE_model_confidence = model_confidence;
    T_INPUT_model_confidence = "${model_confidence}/artifact";
    T_NODE_model_diagnostics = model_diagnostics;
    T_INPUT_model_diagnostics = "${model_diagnostics}/artifact";
    T_NODE_model_fit_stats = model_fit_stats;
    T_INPUT_model_fit_stats = "${model_fit_stats}/artifact";
    T_NODE_model_predictions = model_predictions;
    T_INPUT_model_predictions = "${model_predictions}/artifact";
    T_NODE_model_residuals = model_residuals;
    T_INPUT_model_residuals = "${model_residuals}/artifact";
    T_NODE_model_wald = model_wald;
    T_INPUT_model_wald = "${model_wald}/artifact";
    T_NODE_roundtrip_nested = roundtrip_nested;
    T_INPUT_roundtrip_nested = "${roundtrip_nested}/artifact";
    T_NODE_segment_counts = segment_counts;
    T_INPUT_segment_counts = "${segment_counts}/artifact";
    T_NODE_source_csv = source_csv;
    T_INPUT_source_csv = "${source_csv}/artifact";
    T_NODE_top_slice = top_slice;
    T_INPUT_top_slice = "${top_slice}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_active_projection=${active_projection}
      export T_INPUT_active_projection=${active_projection}/artifact
      export T_NODE_aggregate_snapshot=${aggregate_snapshot}
      export T_INPUT_aggregate_snapshot=${aggregate_snapshot}/artifact
      export T_NODE_compute_features=${compute_features}
      export T_INPUT_compute_features=${compute_features}/artifact
      export T_NODE_grouped_summary=${grouped_summary}
      export T_INPUT_grouped_summary=${grouped_summary}/artifact
      export T_NODE_ipc_roundtrip=${ipc_roundtrip}
      export T_INPUT_ipc_roundtrip=${ipc_roundtrip}/artifact
      export T_NODE_model_anova=${model_anova}
      export T_INPUT_model_anova=${model_anova}/artifact
      export T_NODE_model_augmented=${model_augmented}
      export T_INPUT_model_augmented=${model_augmented}/artifact
      export T_NODE_model_coefficients=${model_coefficients}
      export T_INPUT_model_coefficients=${model_coefficients}/artifact
      export T_NODE_model_confidence=${model_confidence}
      export T_INPUT_model_confidence=${model_confidence}/artifact
      export T_NODE_model_diagnostics=${model_diagnostics}
      export T_INPUT_model_diagnostics=${model_diagnostics}/artifact
      export T_NODE_model_fit_stats=${model_fit_stats}
      export T_INPUT_model_fit_stats=${model_fit_stats}/artifact
      export T_NODE_model_predictions=${model_predictions}
      export T_INPUT_model_predictions=${model_predictions}/artifact
      export T_NODE_model_residuals=${model_residuals}
      export T_INPUT_model_residuals=${model_residuals}/artifact
      export T_NODE_model_wald=${model_wald}
      export T_INPUT_model_wald=${model_wald}/artifact
      export T_NODE_roundtrip_nested=${roundtrip_nested}
      export T_INPUT_roundtrip_nested=${roundtrip_nested}/artifact
      export T_NODE_segment_counts=${segment_counts}
      export T_INPUT_segment_counts=${segment_counts}/artifact
      export T_NODE_source_csv=${source_csv}
      export T_INPUT_source_csv=${source_csv}/artifact
      export T_NODE_top_slice=${top_slice}
      export T_INPUT_top_slice=${top_slice}/artifact

      cat << EOF > node_script.t

EOF









      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "if (file_exists(\"$T_NODE_active_projection/class\") && (read_file(\"$T_NODE_active_projection/class\") == \"VError\" || read_file(\"$T_NODE_active_projection/class\") == \"VError\\n\" || read_file(\"$T_NODE_active_projection/class\") == \"Error\" || read_file(\"$T_NODE_active_projection/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_active_projection = deserialize(\"$T_NODE_active_projection/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_active_projection = read_ipc(\"$T_NODE_active_projection/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_aggregate_snapshot/class\") && (read_file(\"$T_NODE_aggregate_snapshot/class\") == \"VError\" || read_file(\"$T_NODE_aggregate_snapshot/class\") == \"VError\\n\" || read_file(\"$T_NODE_aggregate_snapshot/class\") == \"Error\" || read_file(\"$T_NODE_aggregate_snapshot/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_aggregate_snapshot = deserialize(\"$T_NODE_aggregate_snapshot/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_aggregate_snapshot = read_ipc(\"$T_NODE_aggregate_snapshot/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_compute_features/class\") && (read_file(\"$T_NODE_compute_features/class\") == \"VError\" || read_file(\"$T_NODE_compute_features/class\") == \"VError\\n\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\" || read_file(\"$T_NODE_compute_features/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_compute_features = deserialize(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_compute_features = read_ipc(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_grouped_summary/class\") && (read_file(\"$T_NODE_grouped_summary/class\") == \"VError\" || read_file(\"$T_NODE_grouped_summary/class\") == \"VError\\n\" || read_file(\"$T_NODE_grouped_summary/class\") == \"Error\" || read_file(\"$T_NODE_grouped_summary/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_grouped_summary = deserialize(\"$T_NODE_grouped_summary/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_grouped_summary = read_ipc(\"$T_NODE_grouped_summary/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_ipc_roundtrip/class\") && (read_file(\"$T_NODE_ipc_roundtrip/class\") == \"VError\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"VError\\n\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"Error\" || read_file(\"$T_NODE_ipc_roundtrip/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_ipc_roundtrip = deserialize(\"$T_NODE_ipc_roundtrip/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_ipc_roundtrip = read_ipc(\"$T_NODE_ipc_roundtrip/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_anova/class\") && (read_file(\"$T_NODE_model_anova/class\") == \"VError\" || read_file(\"$T_NODE_model_anova/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_anova/class\") == \"Error\" || read_file(\"$T_NODE_model_anova/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_anova = deserialize(\"$T_NODE_model_anova/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_anova = read_ipc(\"$T_NODE_model_anova/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_augmented/class\") && (read_file(\"$T_NODE_model_augmented/class\") == \"VError\" || read_file(\"$T_NODE_model_augmented/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_augmented/class\") == \"Error\" || read_file(\"$T_NODE_model_augmented/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_augmented = deserialize(\"$T_NODE_model_augmented/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_augmented = read_ipc(\"$T_NODE_model_augmented/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_coefficients/class\") && (read_file(\"$T_NODE_model_coefficients/class\") == \"VError\" || read_file(\"$T_NODE_model_coefficients/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_coefficients/class\") == \"Error\" || read_file(\"$T_NODE_model_coefficients/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_coefficients = deserialize(\"$T_NODE_model_coefficients/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_coefficients = read_ipc(\"$T_NODE_model_coefficients/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_confidence/class\") && (read_file(\"$T_NODE_model_confidence/class\") == \"VError\" || read_file(\"$T_NODE_model_confidence/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_confidence/class\") == \"Error\" || read_file(\"$T_NODE_model_confidence/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_confidence = deserialize(\"$T_NODE_model_confidence/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_confidence = read_ipc(\"$T_NODE_model_confidence/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_diagnostics/class\") && (read_file(\"$T_NODE_model_diagnostics/class\") == \"VError\" || read_file(\"$T_NODE_model_diagnostics/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_diagnostics/class\") == \"Error\" || read_file(\"$T_NODE_model_diagnostics/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_diagnostics = deserialize(\"$T_NODE_model_diagnostics/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_diagnostics = read_ipc(\"$T_NODE_model_diagnostics/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_fit_stats/class\") && (read_file(\"$T_NODE_model_fit_stats/class\") == \"VError\" || read_file(\"$T_NODE_model_fit_stats/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_fit_stats/class\") == \"Error\" || read_file(\"$T_NODE_model_fit_stats/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_fit_stats = deserialize(\"$T_NODE_model_fit_stats/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_fit_stats = deserialize(\"$T_NODE_model_fit_stats/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_predictions/class\") && (read_file(\"$T_NODE_model_predictions/class\") == \"VError\" || read_file(\"$T_NODE_model_predictions/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_predictions/class\") == \"Error\" || read_file(\"$T_NODE_model_predictions/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_predictions = deserialize(\"$T_NODE_model_predictions/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_predictions = deserialize(\"$T_NODE_model_predictions/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_residuals/class\") && (read_file(\"$T_NODE_model_residuals/class\") == \"VError\" || read_file(\"$T_NODE_model_residuals/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_residuals/class\") == \"Error\" || read_file(\"$T_NODE_model_residuals/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_residuals = deserialize(\"$T_NODE_model_residuals/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_residuals = read_ipc(\"$T_NODE_model_residuals/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_model_wald/class\") && (read_file(\"$T_NODE_model_wald/class\") == \"VError\" || read_file(\"$T_NODE_model_wald/class\") == \"VError\\n\" || read_file(\"$T_NODE_model_wald/class\") == \"Error\" || read_file(\"$T_NODE_model_wald/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_model_wald = deserialize(\"$T_NODE_model_wald/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_model_wald = deserialize(\"$T_NODE_model_wald/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_roundtrip_nested/class\") && (read_file(\"$T_NODE_roundtrip_nested/class\") == \"VError\" || read_file(\"$T_NODE_roundtrip_nested/class\") == \"VError\\n\" || read_file(\"$T_NODE_roundtrip_nested/class\") == \"Error\" || read_file(\"$T_NODE_roundtrip_nested/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_roundtrip_nested = deserialize(\"$T_NODE_roundtrip_nested/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_roundtrip_nested = read_ipc(\"$T_NODE_roundtrip_nested/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_segment_counts/class\") && (read_file(\"$T_NODE_segment_counts/class\") == \"VError\" || read_file(\"$T_NODE_segment_counts/class\") == \"VError\\n\" || read_file(\"$T_NODE_segment_counts/class\") == \"Error\" || read_file(\"$T_NODE_segment_counts/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_segment_counts = deserialize(\"$T_NODE_segment_counts/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_segment_counts = read_ipc(\"$T_NODE_segment_counts/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_source_csv/class\") && (read_file(\"$T_NODE_source_csv/class\") == \"VError\" || read_file(\"$T_NODE_source_csv/class\") == \"VError\\n\" || read_file(\"$T_NODE_source_csv/class\") == \"Error\" || read_file(\"$T_NODE_source_csv/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_source_csv = deserialize(\"$T_NODE_source_csv/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_source_csv = read_ipc(\"$T_NODE_source_csv/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_top_slice/class\") && (read_file(\"$T_NODE_top_slice/class\") == \"VError\" || read_file(\"$T_NODE_top_slice/class\") == \"VError\\n\" || read_file(\"$T_NODE_top_slice/class\") == \"Error\" || read_file(\"$T_NODE_top_slice/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_top_slice = deserialize(\"$T_NODE_top_slice/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_top_slice = read_ipc(\"$T_NODE_top_slice/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
top_slice = __dep_top_slice
EOF
      cat <<'EOF' >> node_script.t
source_csv = __dep_source_csv
EOF
      cat <<'EOF' >> node_script.t
segment_counts = __dep_segment_counts
EOF
      cat <<'EOF' >> node_script.t
roundtrip_nested = __dep_roundtrip_nested
EOF
      cat <<'EOF' >> node_script.t
model_wald = __dep_model_wald
EOF
      cat <<'EOF' >> node_script.t
model_residuals = __dep_model_residuals
EOF
      cat <<'EOF' >> node_script.t
model_predictions = __dep_model_predictions
EOF
      cat <<'EOF' >> node_script.t
model_fit_stats = __dep_model_fit_stats
EOF
      cat <<'EOF' >> node_script.t
model_diagnostics = __dep_model_diagnostics
EOF
      cat <<'EOF' >> node_script.t
model_confidence = __dep_model_confidence
EOF
      cat <<'EOF' >> node_script.t
model_coefficients = __dep_model_coefficients
EOF
      cat <<'EOF' >> node_script.t
model_augmented = __dep_model_augmented
EOF
      cat <<'EOF' >> node_script.t
model_anova = __dep_model_anova
EOF
      cat <<'EOF' >> node_script.t
ipc_roundtrip = __dep_ipc_roundtrip
EOF
      cat <<'EOF' >> node_script.t
grouped_summary = __dep_grouped_summary
EOF
      cat <<'EOF' >> node_script.t
compute_features = __dep_compute_features
EOF
      cat <<'EOF' >> node_script.t
aggregate_snapshot = __dep_aggregate_snapshot
EOF
      cat <<'EOF' >> node_script.t
active_projection = __dep_active_projection
EOF

      echo "      __node_result = {" >> node_script.t
      cat <<'EOF' >> node_script.t
assert(nrow(source_csv) == 6, "CSV roundtrip should preserve all rows")
            assert(get(pull(ipc_roundtrip, $note), 0) == "alpha,beta", "CSV quoting should roundtrip commas")
            assert(nrow(top_slice) == 3, "slice() should keep the requested number of rows")
            assert(nrow(active_projection) == 4, "filter() should keep the four flagged rows")
            assert(ncol(active_projection) == 5, "select() should project the requested columns")
            assert(sum(pull(segment_counts, $n)) == 6, "count() totals should match the input rows")
            assert(nrow(grouped_summary) == 3, "summarize() should emit one row per segment")
            assert(get(pull(aggregate_snapshot, $unique_segments), 0) == 3, "aggregate snapshot should see three segments")
            assert(nrow(roundtrip_nested) == nrow(compute_features), "nest()/unnest() should preserve row count")
            assert(ncol(model_diagnostics) > ncol(compute_features), "add_diagnostics() should append diagnostic columns")
            assert(nrow(model_predictions) == nrow(compute_features), "predict() should return one row per input row")
            assert(ncol(model_augmented) > ncol(compute_features), "add_diagnostics() should append fitted values")
            assert(nrow(model_residuals) == nrow(compute_features), "residuals() should return one row per input row")
            assert(nrow(model_coefficients) == 4, "coef() should expose all model terms")
            assert(nrow(model_confidence) == 4, "conf_int() should expose all confidence intervals")
            assert(nrow(model_fit_stats) == 2, "fit_stats() should stack the reduced and full models")
            assert(nrow(model_anova) >= 1, "anova() should produce a comparison table")
            assert(nrow(model_wald) == 1, "wald_test() should return a single summary row")
            model = lm(data = compute_features, formula = amount ~ offset + stage)
            model_summary = summary(model)
            corr = cor(pull(compute_features, $amount), pull(compute_features, $net))
            expected_model_terms = 4 -- (Intercept), offset, stage.medium, stage.high
            assert(nrow(model_summary._tidy_df) == expected_model_terms, "lm() summary should expose all model terms")
            assert(!is_na(corr), "cor() should produce a numeric result")
            [
                status: "ok",
                corr: corr,
                rows: nrow(compute_features),
                grouped_rows: nrow(grouped_summary),
                diagnostics_cols: ncol(model_diagnostics)
            ]
EOF
      echo "      }" >> node_script.t
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
    buildInputs = [ tBin source_csv ipc_roundtrip compute_features top_slice active_projection segment_counts grouped_summary aggregate_snapshot nested_groups roundtrip_nested model_diagnostics model_predictions model_augmented model_residuals model_coefficients model_confidence model_fit_stats model_anova model_wald validation_report projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${source_csv} $out/source_csv
      cp -r ${ipc_roundtrip} $out/ipc_roundtrip
      cp -r ${compute_features} $out/compute_features
      cp -r ${top_slice} $out/top_slice
      cp -r ${active_projection} $out/active_projection
      cp -r ${segment_counts} $out/segment_counts
      cp -r ${grouped_summary} $out/grouped_summary
      cp -r ${aggregate_snapshot} $out/aggregate_snapshot
      cp -r ${nested_groups} $out/nested_groups
      cp -r ${roundtrip_nested} $out/roundtrip_nested
      cp -r ${model_diagnostics} $out/model_diagnostics
      cp -r ${model_predictions} $out/model_predictions
      cp -r ${model_augmented} $out/model_augmented
      cp -r ${model_residuals} $out/model_residuals
      cp -r ${model_coefficients} $out/model_coefficients
      cp -r ${model_confidence} $out/model_confidence
      cp -r ${model_fit_stats} $out/model_fit_stats
      cp -r ${model_anova} $out/model_anova
      cp -r ${model_wald} $out/model_wald
      cp -r ${validation_report} $out/validation_report
    '';
  };
}

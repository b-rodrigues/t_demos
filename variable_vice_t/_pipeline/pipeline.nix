
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

  test_shadow_builtins = stdenv.mkDerivation {
    name = "test_shadow_builtins";
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
      __node_result = { r1 = eval(to_expr({ sum = 42 })); r2 = eval(to_expr({ print := 99 })); ok1 = is_error(r1); ok2 = is_error(r2); [test: "shadow_builtins", passed: (ok1 && ok2), sum_code: if (is_error(r1)) { error_code(r1) } else { "none" }, print_code: if (is_error(r2)) { error_code(r2) } else { "none" }] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_type_mismatch_arith = stdenv.mkDerivation {
    name = "test_type_mismatch_arith";
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
      __node_result = { r1 = (1 + "hello"); r2 = ([1, 2] + 3); r3 = ("a" > 5); ok1 = is_error(r1); ok2 = is_error(r2); ok3 = is_error(r3); [test: "type_mismatch_arith", passed: ((ok1 && ok2) && ok3)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_type_mismatch_func = stdenv.mkDerivation {
    name = "test_type_mismatch_func";
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
      __node_result = { r1 = head(42); r2 = sum("hello"); r3 = mean(true); ok1 = is_error(r1); ok2 = is_error(r2); ok3 = is_error(r3); [test: "type_mismatch_func", passed: ((ok1 && ok2) && ok3)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_name_suggestions = stdenv.mkDerivation {
    name = "test_name_suggestions";
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
      __node_result = { r1 = prnt("hi"); r2 = slect([1, 2, 3]); r3 = flter(1); ok1 = is_error(r1); ok2 = is_error(r2); ok3 = is_error(r3); msg1 = if (is_error(r1)) { error_msg(r1) } else { "" }; has_suggest = str_detect(msg1, "print"); [test: "name_suggestions", passed: (((ok1 && ok2) && ok3) && has_suggest), msg: msg1] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_div_zero_short = stdenv.mkDerivation {
    name = "test_div_zero_short";
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
      __node_result = { result = ((1 / 0) |> \(x) (x + 1)); ok = is_error(result); [test: "div_zero_short", passed: ok, code: if (ok) { error_code(result) } else { "none" }] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_div_zero_recover = stdenv.mkDerivation {
    name = "test_div_zero_recover";
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
      __node_result = { result = ((1 / 0) ?|> \(x) if (is_error(x)) { 0 } else { x }); ok = (!is_error(result) && (result == 0)); [test: "div_zero_recover", passed: ok, value: result] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_deep_nesting = stdenv.mkDerivation {
    name = "test_deep_nesting";
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
      __node_result = { nested = (seq(1, 30) |> map(\(x) [x, (x * 2)])); passed = (length(nested) == 30); [test: "deep_nesting", passed: passed, depth: length(nested)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_error_chain = stdenv.mkDerivation {
    name = "test_error_chain";
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
      __node_result = { e1 = error("E1", "first"); e2 = error("E2", "second"); e_chain = error_chain(e1, e2); passed = ((is_error(e_chain) && (error_code(e_chain) == "GenericError")) && str_detect(error_msg(e_chain), "first")); [test: "error_chain", passed: passed, chain_message: error_msg(e_chain)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_rm = stdenv.mkDerivation {
    name = "test_rm";
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
      __node_result = { x = 42; result = rm("x"); ok = is_na(result); [test: "rm_variable", passed: ok] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_rm_builtin = stdenv.mkDerivation {
    name = "test_rm_builtin";
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
      __node_result = { result = rm("print"); ok = (is_na(result) || is_error(result)); [test: "rm_builtin", passed: ok, result_type: type(result)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_match_na = stdenv.mkDerivation {
    name = "test_match_na";
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
      __node_result = { r = match(NA) { Int => "int", Float => "float", Bool => "bool", _ => "fallback" }; [test: "match_na", passed: (r == "int"), result: r] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_match_error = stdenv.mkDerivation {
    name = "test_match_error";
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
      __node_result = { r = match(error("MY_CODE", "something broke")) { e => str_sprintf("caught %s: %s", error_code(e), error_msg(e)), _ => "no match" }; [test: "match_error", passed: (str_detect(r, "GenericError") && str_detect(r, "something broke")), result: r] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_reassignment = stdenv.mkDerivation {
    name = "test_reassignment";
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
      __node_result = { a = 42; a := "hello"; a := [1, 2, 3]; ok1 = (((get(a, 0) == 1) && (get(a, 1) == 2)) && (get(a, 2) == 3)); a := [x: 10]; ok2 = (type(a) == "Dict"); [test: "reassignment", passed: (ok1 && ok2)] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_large_pipe = stdenv.mkDerivation {
    name = "test_large_pipe";
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
      __node_result = { result = ((((seq(1, 30) |> map(\(x) (x * 2))) |> map(\(x) (x + 1))) |> map(\(x) (x * x))) |> length()); [test: "large_pipe", passed: (result == 30), result: result] }
EOF
      echo "      if (is_error(__node_result)) { res1 = serialize(__node_result, \"$out/artifact\") } else { res1 = serialize(__node_result, \"$out/artifact\") }" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(__node_result))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_factor_edges = stdenv.mkDerivation {
    name = "test_factor_edges";
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
      __node_result = { f1 = to_factor(["a", "b", "a"], levels = ["a", "b", "c"]); r1 = levels(f1); ok1 = (length(r1) == 3); f2 = to_factor(["low", "high", "medium"], levels = ["low", "medium", "high"], ordered = true); ok2 = !is_error(f2); [test: "factor_edges", passed: (ok1 && ok2)] }
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
    buildInputs = [ tBin test_deep_nesting test_div_zero_recover test_div_zero_short test_error_chain test_factor_edges test_large_pipe test_match_error test_match_na test_name_suggestions test_reassignment test_rm test_rm_builtin test_shadow_builtins test_type_mismatch_arith test_type_mismatch_func ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    JULIA_COPY_STACKS = "1";
    MPLCONFIGDIR = ".";
    HOME = ".";
    LD_LIBRARY_PATH = "${pkgs.gcc.cc.lib}/lib:${pkgs.avahi}/lib${if pyResolver == "uv" then ":${pkgs.openblas}/lib:${pkgs.gfortran.cc.lib}/lib" else ""}";
    PYTHONPATH = "${tBin}/share/tlang/py-package/src";
    JULIA_LOAD_PATH = ":${tlangJl}";
    src = sources;

    T_NODE_test_deep_nesting = test_deep_nesting;
    T_INPUT_test_deep_nesting = "${test_deep_nesting}/artifact";
    T_NODE_test_div_zero_recover = test_div_zero_recover;
    T_INPUT_test_div_zero_recover = "${test_div_zero_recover}/artifact";
    T_NODE_test_div_zero_short = test_div_zero_short;
    T_INPUT_test_div_zero_short = "${test_div_zero_short}/artifact";
    T_NODE_test_error_chain = test_error_chain;
    T_INPUT_test_error_chain = "${test_error_chain}/artifact";
    T_NODE_test_factor_edges = test_factor_edges;
    T_INPUT_test_factor_edges = "${test_factor_edges}/artifact";
    T_NODE_test_large_pipe = test_large_pipe;
    T_INPUT_test_large_pipe = "${test_large_pipe}/artifact";
    T_NODE_test_match_error = test_match_error;
    T_INPUT_test_match_error = "${test_match_error}/artifact";
    T_NODE_test_match_na = test_match_na;
    T_INPUT_test_match_na = "${test_match_na}/artifact";
    T_NODE_test_name_suggestions = test_name_suggestions;
    T_INPUT_test_name_suggestions = "${test_name_suggestions}/artifact";
    T_NODE_test_reassignment = test_reassignment;
    T_INPUT_test_reassignment = "${test_reassignment}/artifact";
    T_NODE_test_rm = test_rm;
    T_INPUT_test_rm = "${test_rm}/artifact";
    T_NODE_test_rm_builtin = test_rm_builtin;
    T_INPUT_test_rm_builtin = "${test_rm_builtin}/artifact";
    T_NODE_test_shadow_builtins = test_shadow_builtins;
    T_INPUT_test_shadow_builtins = "${test_shadow_builtins}/artifact";
    T_NODE_test_type_mismatch_arith = test_type_mismatch_arith;
    T_INPUT_test_type_mismatch_arith = "${test_type_mismatch_arith}/artifact";
    T_NODE_test_type_mismatch_func = test_type_mismatch_func;
    T_INPUT_test_type_mismatch_func = "${test_type_mismatch_func}/artifact";
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_test_deep_nesting=${test_deep_nesting}
      export T_INPUT_test_deep_nesting=${test_deep_nesting}/artifact
      export T_NODE_test_div_zero_recover=${test_div_zero_recover}
      export T_INPUT_test_div_zero_recover=${test_div_zero_recover}/artifact
      export T_NODE_test_div_zero_short=${test_div_zero_short}
      export T_INPUT_test_div_zero_short=${test_div_zero_short}/artifact
      export T_NODE_test_error_chain=${test_error_chain}
      export T_INPUT_test_error_chain=${test_error_chain}/artifact
      export T_NODE_test_factor_edges=${test_factor_edges}
      export T_INPUT_test_factor_edges=${test_factor_edges}/artifact
      export T_NODE_test_large_pipe=${test_large_pipe}
      export T_INPUT_test_large_pipe=${test_large_pipe}/artifact
      export T_NODE_test_match_error=${test_match_error}
      export T_INPUT_test_match_error=${test_match_error}/artifact
      export T_NODE_test_match_na=${test_match_na}
      export T_INPUT_test_match_na=${test_match_na}/artifact
      export T_NODE_test_name_suggestions=${test_name_suggestions}
      export T_INPUT_test_name_suggestions=${test_name_suggestions}/artifact
      export T_NODE_test_reassignment=${test_reassignment}
      export T_INPUT_test_reassignment=${test_reassignment}/artifact
      export T_NODE_test_rm=${test_rm}
      export T_INPUT_test_rm=${test_rm}/artifact
      export T_NODE_test_rm_builtin=${test_rm_builtin}
      export T_INPUT_test_rm_builtin=${test_rm_builtin}/artifact
      export T_NODE_test_shadow_builtins=${test_shadow_builtins}
      export T_INPUT_test_shadow_builtins=${test_shadow_builtins}/artifact
      export T_NODE_test_type_mismatch_arith=${test_type_mismatch_arith}
      export T_INPUT_test_type_mismatch_arith=${test_type_mismatch_arith}/artifact
      export T_NODE_test_type_mismatch_func=${test_type_mismatch_func}
      export T_INPUT_test_type_mismatch_func=${test_type_mismatch_func}/artifact

      cat << EOF > node_script.t

EOF












      echo "if (file_exists(\"$T_NODE_test_deep_nesting/class\") && (read_file(\"$T_NODE_test_deep_nesting/class\") == \"VError\" || read_file(\"$T_NODE_test_deep_nesting/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_deep_nesting/class\") == \"Error\" || read_file(\"$T_NODE_test_deep_nesting/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_deep_nesting = deserialize(\"$T_NODE_test_deep_nesting/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_deep_nesting = deserialize(\"$T_NODE_test_deep_nesting/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_div_zero_recover/class\") && (read_file(\"$T_NODE_test_div_zero_recover/class\") == \"VError\" || read_file(\"$T_NODE_test_div_zero_recover/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_div_zero_recover/class\") == \"Error\" || read_file(\"$T_NODE_test_div_zero_recover/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_div_zero_recover = deserialize(\"$T_NODE_test_div_zero_recover/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_div_zero_recover = deserialize(\"$T_NODE_test_div_zero_recover/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_div_zero_short/class\") && (read_file(\"$T_NODE_test_div_zero_short/class\") == \"VError\" || read_file(\"$T_NODE_test_div_zero_short/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_div_zero_short/class\") == \"Error\" || read_file(\"$T_NODE_test_div_zero_short/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_div_zero_short = deserialize(\"$T_NODE_test_div_zero_short/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_div_zero_short = deserialize(\"$T_NODE_test_div_zero_short/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_error_chain/class\") && (read_file(\"$T_NODE_test_error_chain/class\") == \"VError\" || read_file(\"$T_NODE_test_error_chain/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_error_chain/class\") == \"Error\" || read_file(\"$T_NODE_test_error_chain/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_error_chain = deserialize(\"$T_NODE_test_error_chain/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_error_chain = deserialize(\"$T_NODE_test_error_chain/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_factor_edges/class\") && (read_file(\"$T_NODE_test_factor_edges/class\") == \"VError\" || read_file(\"$T_NODE_test_factor_edges/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_factor_edges/class\") == \"Error\" || read_file(\"$T_NODE_test_factor_edges/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_factor_edges = deserialize(\"$T_NODE_test_factor_edges/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_factor_edges = deserialize(\"$T_NODE_test_factor_edges/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_large_pipe/class\") && (read_file(\"$T_NODE_test_large_pipe/class\") == \"VError\" || read_file(\"$T_NODE_test_large_pipe/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_large_pipe/class\") == \"Error\" || read_file(\"$T_NODE_test_large_pipe/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_large_pipe = deserialize(\"$T_NODE_test_large_pipe/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_large_pipe = deserialize(\"$T_NODE_test_large_pipe/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_match_error/class\") && (read_file(\"$T_NODE_test_match_error/class\") == \"VError\" || read_file(\"$T_NODE_test_match_error/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_match_error/class\") == \"Error\" || read_file(\"$T_NODE_test_match_error/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_match_error = deserialize(\"$T_NODE_test_match_error/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_match_error = deserialize(\"$T_NODE_test_match_error/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_match_na/class\") && (read_file(\"$T_NODE_test_match_na/class\") == \"VError\" || read_file(\"$T_NODE_test_match_na/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_match_na/class\") == \"Error\" || read_file(\"$T_NODE_test_match_na/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_match_na = deserialize(\"$T_NODE_test_match_na/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_match_na = deserialize(\"$T_NODE_test_match_na/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_name_suggestions/class\") && (read_file(\"$T_NODE_test_name_suggestions/class\") == \"VError\" || read_file(\"$T_NODE_test_name_suggestions/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_name_suggestions/class\") == \"Error\" || read_file(\"$T_NODE_test_name_suggestions/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_name_suggestions = deserialize(\"$T_NODE_test_name_suggestions/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_name_suggestions = deserialize(\"$T_NODE_test_name_suggestions/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_reassignment/class\") && (read_file(\"$T_NODE_test_reassignment/class\") == \"VError\" || read_file(\"$T_NODE_test_reassignment/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_reassignment/class\") == \"Error\" || read_file(\"$T_NODE_test_reassignment/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_reassignment = deserialize(\"$T_NODE_test_reassignment/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_reassignment = deserialize(\"$T_NODE_test_reassignment/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_rm/class\") && (read_file(\"$T_NODE_test_rm/class\") == \"VError\" || read_file(\"$T_NODE_test_rm/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_rm/class\") == \"Error\" || read_file(\"$T_NODE_test_rm/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_rm = deserialize(\"$T_NODE_test_rm/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_rm = deserialize(\"$T_NODE_test_rm/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_rm_builtin/class\") && (read_file(\"$T_NODE_test_rm_builtin/class\") == \"VError\" || read_file(\"$T_NODE_test_rm_builtin/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_rm_builtin/class\") == \"Error\" || read_file(\"$T_NODE_test_rm_builtin/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_rm_builtin = deserialize(\"$T_NODE_test_rm_builtin/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_rm_builtin = deserialize(\"$T_NODE_test_rm_builtin/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_shadow_builtins/class\") && (read_file(\"$T_NODE_test_shadow_builtins/class\") == \"VError\" || read_file(\"$T_NODE_test_shadow_builtins/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_shadow_builtins/class\") == \"Error\" || read_file(\"$T_NODE_test_shadow_builtins/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_shadow_builtins = deserialize(\"$T_NODE_test_shadow_builtins/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_shadow_builtins = deserialize(\"$T_NODE_test_shadow_builtins/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_type_mismatch_arith/class\") && (read_file(\"$T_NODE_test_type_mismatch_arith/class\") == \"VError\" || read_file(\"$T_NODE_test_type_mismatch_arith/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_type_mismatch_arith/class\") == \"Error\" || read_file(\"$T_NODE_test_type_mismatch_arith/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_type_mismatch_arith = deserialize(\"$T_NODE_test_type_mismatch_arith/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_type_mismatch_arith = deserialize(\"$T_NODE_test_type_mismatch_arith/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      echo "if (file_exists(\"$T_NODE_test_type_mismatch_func/class\") && (read_file(\"$T_NODE_test_type_mismatch_func/class\") == \"VError\" || read_file(\"$T_NODE_test_type_mismatch_func/class\") == \"VError\\n\" || read_file(\"$T_NODE_test_type_mismatch_func/class\") == \"Error\" || read_file(\"$T_NODE_test_type_mismatch_func/class\") == \"Error\\n\")) {" >> node_script.t
      echo "  __dep_test_type_mismatch_func = deserialize(\"$T_NODE_test_type_mismatch_func/artifact\")" >> node_script.t
      echo "} else {" >> node_script.t
      echo "  __dep_test_type_mismatch_func = deserialize(\"$T_NODE_test_type_mismatch_func/artifact\")" >> node_script.t
      echo "}" >> node_script.t
      cat <<'EOF' >> node_script.t
test_type_mismatch_func = __dep_test_type_mismatch_func
EOF
      cat <<'EOF' >> node_script.t
test_type_mismatch_arith = __dep_test_type_mismatch_arith
EOF
      cat <<'EOF' >> node_script.t
test_shadow_builtins = __dep_test_shadow_builtins
EOF
      cat <<'EOF' >> node_script.t
test_rm_builtin = __dep_test_rm_builtin
EOF
      cat <<'EOF' >> node_script.t
test_rm = __dep_test_rm
EOF
      cat <<'EOF' >> node_script.t
test_reassignment = __dep_test_reassignment
EOF
      cat <<'EOF' >> node_script.t
test_name_suggestions = __dep_test_name_suggestions
EOF
      cat <<'EOF' >> node_script.t
test_match_na = __dep_test_match_na
EOF
      cat <<'EOF' >> node_script.t
test_match_error = __dep_test_match_error
EOF
      cat <<'EOF' >> node_script.t
test_large_pipe = __dep_test_large_pipe
EOF
      cat <<'EOF' >> node_script.t
test_factor_edges = __dep_test_factor_edges
EOF
      cat <<'EOF' >> node_script.t
test_error_chain = __dep_test_error_chain
EOF
      cat <<'EOF' >> node_script.t
test_div_zero_short = __dep_test_div_zero_short
EOF
      cat <<'EOF' >> node_script.t
test_div_zero_recover = __dep_test_div_zero_recover
EOF
      cat <<'EOF' >> node_script.t
test_deep_nesting = __dep_test_deep_nesting
EOF

      cat <<'EOF' >> node_script.t
      __node_result = { results = [test_shadow_builtins, test_type_mismatch_arith, test_type_mismatch_func, test_name_suggestions, test_div_zero_short, test_div_zero_recover, test_deep_nesting, test_error_chain, test_rm, test_rm_builtin, test_match_na, test_match_error, test_reassignment, test_large_pipe, test_factor_edges]; passed_counts = (results |> map(\(r) if ((!is_error(r) && r.passed)) { 1 } else { 0 })); n_fail = (length(results) - sum(passed_counts)); if ((n_fail > 0)) { print("FAILURES:"); print((results |> map(\(r) if (!is_error(r)) { r.test } else { error_msg(r) }))); assert((n_fail == 0), str_sprintf("variable_vice_t: %d tests failed", n_fail)) } else NA; [status: "ok", total: 15, passed: (15 - n_fail), failures: n_fail] }
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
    buildInputs = [ tBin test_shadow_builtins test_type_mismatch_arith test_type_mismatch_func test_name_suggestions test_div_zero_short test_div_zero_recover test_deep_nesting test_error_chain test_rm test_rm_builtin test_match_na test_match_error test_reassignment test_large_pipe test_factor_edges validation projectTlangPkgSet.tlang-julia-path ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${test_shadow_builtins} $out/test_shadow_builtins
      cp -r ${test_type_mismatch_arith} $out/test_type_mismatch_arith
      cp -r ${test_type_mismatch_func} $out/test_type_mismatch_func
      cp -r ${test_name_suggestions} $out/test_name_suggestions
      cp -r ${test_div_zero_short} $out/test_div_zero_short
      cp -r ${test_div_zero_recover} $out/test_div_zero_recover
      cp -r ${test_deep_nesting} $out/test_deep_nesting
      cp -r ${test_error_chain} $out/test_error_chain
      cp -r ${test_rm} $out/test_rm
      cp -r ${test_rm_builtin} $out/test_rm_builtin
      cp -r ${test_match_na} $out/test_match_na
      cp -r ${test_match_error} $out/test_match_error
      cp -r ${test_reassignment} $out/test_reassignment
      cp -r ${test_large_pipe} $out/test_large_pipe
      cp -r ${test_factor_edges} $out/test_factor_edges
      cp -r ${validation} $out/validation
    '';
  };
}

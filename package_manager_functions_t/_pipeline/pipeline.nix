
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

  package_checks = stdenv.mkDerivation {
    name = "package_checks";
    buildInputs = [ tBin  ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t
EOF













      cat <<'EOF' >> node_script.t
      package_checks = { run(str_sprintf("sh -lc 'rm -rf \"%s\" && mkdir -p \"%s\"'", package_workspace, package_workspace)); package_init_output = run(str_sprintf("sh -lc 'cd \"%s\" && t init --package pm_demo_pkg --author \"Demo User <demo@example.com>\" --license MIT --context small'", package_workspace)); assert_file_exists(path_join(package_root, "DESCRIPTION.toml")); assert_file_exists(path_join(package_root, "src", "main.t")); assert_file_exists(path_join(package_root, "tests", "test-pm_demo_pkg.t")); assert_file_exists(path_join(package_root, "docs", "index.md")); run(str_sprintf("sh -lc 'cd \"%s\" && t run src/main.t'", package_root)); run(str_sprintf("sh -lc 'cd \"%s\" && t test'", package_root)); run(str_sprintf("sh -lc 'cd \"%s\" && t doc --parse --generate'", package_root)); assert_file_exists(path_join(package_root, "docs", "reference", "index.md")); run(str_sprintf("sh -lc 'cd \"%s\" && t doctor > doctor.txt && grep -q \"Detected T Package\" doctor.txt'", package_root)); run(str_sprintf("sh -lc 'cd \"%s\" && T_BIN=$(command -v t) && SAVED_PATH=$PATH && PATH=\"\" \"$T_BIN\" docs > docs-open.txt 2>&1 && PATH=$SAVED_PATH grep -q \"Documentation location:\" docs-open.txt'", package_root)); run(str_sprintf("sh -lc 'cd \"%s\" && t update'", package_root)); assert_file_exists(path_join(package_root, "flake.lock")); package_import_output = run(str_sprintf("sh -lc 'cd \"%s\" && T_PACKAGE_PATH=\"%s\" t run \"%s\"'", package_workspace, package_workspace, consumer_script)); [init_output: package_init_output, docs_index: path_join(package_root, "docs", "reference", "index.md"), import_output: package_import_output, lockfile: path_join(package_root, "flake.lock")] }
EOF
      echo "      res1 = serialize(package_checks, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(package_checks))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  project_checks = stdenv.mkDerivation {
    name = "project_checks";
    buildInputs = [ tBin  ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;


    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t
EOF













      cat <<'EOF' >> node_script.t
      project_checks = { run(str_sprintf("sh -lc 'rm -rf \"%s\" && mkdir -p \"%s\"'", project_workspace, project_workspace)); project_init_output = run(str_sprintf("sh -lc 'cd \"%s\" && t init --project pm_demo_project --author \"Demo User <demo@example.com>\" --license MIT --context small'", project_workspace)); assert_file_exists(path_join(project_root, "tproject.toml")); assert_file_exists(path_join(project_root, "src", "pipeline.t")); assert_dir_exists(path_join(project_root, "data")); assert_dir_exists(path_join(project_root, "outputs")); run(str_sprintf("sh -lc 'cd \"%s\" && t run src/pipeline.t > project-run.txt && grep -q \"Hello from pm_demo_project pipeline!\" project-run.txt'", project_root)); run(str_sprintf("sh -lc 'cd \"%s\" && t doctor > doctor.txt && grep -q \"Detected T Project\" doctor.txt'", project_root)); run(str_sprintf("sh -lc 'cd \"%s\" && t update'", project_root)); assert_file_exists(path_join(project_root, "flake.lock")); [init_output: project_init_output, lockfile: path_join(project_root, "flake.lock"), pipeline_script: path_join(project_root, "src", "pipeline.t")] }
EOF
      echo "      res1 = serialize(project_checks, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(project_checks))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin package_checks project_checks ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${package_checks} $out/package_checks
      cp -r ${project_checks} $out/project_checks
    '';
  };
}

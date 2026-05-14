
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

  baseline_data = stdenv.mkDerivation {
    name = "baseline_data";
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













      echo "      baseline_data = {" >> node_script.t
      cat <<'EOF' >> node_script.t
read_csv("data/mtcars.csv", separator = "|")
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(baseline_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(baseline_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  baseline_stats = stdenv.mkDerivation {
    name = "baseline_stats";
    buildInputs = [ tBin baseline_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_baseline_data = baseline_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_baseline_data=${baseline_data}

      cat << EOF > node_script.t
EOF











      echo "baseline_data = read_arrow(\"$T_NODE_baseline_data/artifact\")" >> node_script.t

      echo "      baseline_stats = {" >> node_script.t
      cat <<'EOF' >> node_script.t
baseline_data |> summarize(
                avg_mpg = mean($mpg)
            )
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(baseline_stats, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(baseline_stats))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  live_data = stdenv.mkDerivation {
    name = "live_data";
    buildInputs = [ tBin baseline_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_baseline_data = baseline_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_baseline_data=${baseline_data}

      cat << EOF > node_script.t
EOF











      echo "baseline_data = read_arrow(\"$T_NODE_baseline_data/artifact\")" >> node_script.t

      echo "      live_data = {" >> node_script.t
      cat <<'EOF' >> node_script.t
baseline_data |> mutate(
                mpg = $mpg + 10.0
            )
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(live_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(live_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  drift_guardrail = stdenv.mkDerivation {
    name = "drift_guardrail";
    buildInputs = [ tBin baseline_stats live_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_baseline_stats = baseline_stats;
    T_NODE_live_data = live_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_baseline_stats=${baseline_stats}
      export T_NODE_live_data=${live_data}

      cat << EOF > node_script.t
EOF











      echo "baseline_stats = read_arrow(\"$T_NODE_baseline_stats/artifact\")" >> node_script.t
      echo "live_data = read_arrow(\"$T_NODE_live_data/artifact\")" >> node_script.t

      echo "      drift_guardrail = {" >> node_script.t
      cat <<'EOF' >> node_script.t
live_stats = live_data |> summarize(avg_mpg = mean($mpg))
            -- Use the enhanced 3-arg get() with a Lens for safe column retrieval
            -- We pipe to get(0) to ensure we have a scalar Number for the abs() function
            b_mpg = get(baseline_stats, col_lens("avg_mpg")) |> get(0)
            l_mpg = get(live_stats, col_lens("avg_mpg")) |> get(0)
            drift_val = abs(l_mpg - b_mpg)
            -- Guardrail Failure Condition (set to 15.0 to PASS by default)
            -- Change to 2.0 to trigger drift detection!
            res = assert(drift_val < 15.0, str_join(["GUARDRAIL FAILURE: mpg drift is ", drift_val]))
            if (is_error(res)) {
                res
            } else {
                true
            }
EOF
      echo "      }" >> node_script.t
      echo "      res1 = t_write_json(drift_guardrail, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(drift_guardrail))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin baseline_data baseline_stats live_data drift_guardrail ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${baseline_data} $out/baseline_data
      cp -r ${baseline_stats} $out/baseline_stats
      cp -r ${live_data} $out/live_data
      cp -r ${drift_guardrail} $out/drift_guardrail
    '';
  };
}

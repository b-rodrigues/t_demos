
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

  raw_data = stdenv.mkDerivation {
    name = "raw_data";
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
      raw_data = to_dataframe([[id: 1, group: "alpha", value: 10], [id: 2, group: "alpha", value: na()], [id: 3, group: "beta", value: 5], [id: 4, group: "beta", value: -2]])
EOF
      echo "      res1 = serialize(raw_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(raw_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  positive_rows = stdenv.mkDerivation {
    name = "positive_rows";
    buildInputs = [ tBin raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_raw_data = raw_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.t
EOF











      echo "raw_data = deserialize(\"$T_NODE_raw_data/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      positive_rows = (raw_data |> filter(($value > 0)))
EOF
      echo "      res1 = serialize(positive_rows, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(positive_rows))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  quiet_positive_rows = stdenv.mkDerivation {
    name = "quiet_positive_rows";
    buildInputs = [ tBin raw_data ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_raw_data = raw_data;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.t
EOF











      echo "raw_data = deserialize(\"$T_NODE_raw_data/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      quiet_positive_rows = ((raw_data |> filter(($value > 0))) |> suppress_warnings)
EOF
      echo "      res1 = serialize(quiet_positive_rows, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(quiet_positive_rows))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  grouped_rows = stdenv.mkDerivation {
    name = "grouped_rows";
    buildInputs = [ tBin quiet_positive_rows ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_quiet_positive_rows = quiet_positive_rows;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_quiet_positive_rows=${quiet_positive_rows}

      cat << EOF > node_script.t
EOF











      echo "quiet_positive_rows = deserialize(\"$T_NODE_quiet_positive_rows/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      grouped_rows = (quiet_positive_rows |> group_by($group))
EOF
      echo "      res1 = serialize(grouped_rows, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(grouped_rows))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  final_summary = stdenv.mkDerivation {
    name = "final_summary";
    buildInputs = [ tBin grouped_rows ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_grouped_rows = grouped_rows;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_grouped_rows=${grouped_rows}

      cat << EOF > node_script.t
EOF











      echo "grouped_rows = deserialize(\"$T_NODE_grouped_rows/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      final_summary = (grouped_rows |> summarize(total = sum($value, na_rm = true)))
EOF
      echo "      res1 = serialize(final_summary, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(final_summary))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin raw_data positive_rows quiet_positive_rows grouped_rows final_summary ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw_data} $out/raw_data
      cp -r ${positive_rows} $out/positive_rows
      cp -r ${quiet_positive_rows} $out/quiet_positive_rows
      cp -r ${grouped_rows} $out/grouped_rows
      cp -r ${final_summary} $out/final_summary
    '';
  };
}

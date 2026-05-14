
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
      raw_data = to_dataframe([[x: 1, y: 3], [x: 2, y: 4]])
EOF
      echo "      res1 = serialize(raw_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(raw_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  final_status = stdenv.mkDerivation {
    name = "final_status";
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
      final_status = (raw_data |> mutate(z = ($x + $y)))
EOF
      echo "      res1 = serialize(final_status, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(final_status))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  extra_step = stdenv.mkDerivation {
    name = "extra_step";
    buildInputs = [ tBin final_status ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_final_status = final_status;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_final_status=${final_status}

      cat << EOF > node_script.t
EOF











      echo "final_status = deserialize(\"$T_NODE_final_status/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      extra_step = (final_status |> mutate(msg = str_join([$z, " - extended"])))
EOF
      echo "      res1 = serialize(extra_step, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(extra_step))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin raw_data final_status extra_step ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw_data} $out/raw_data
      cp -r ${final_status} $out/final_status
      cp -r ${extra_step} $out/extra_step
    '';
  };
}

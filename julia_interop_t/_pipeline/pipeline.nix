
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
      raw_data = read_csv("data/mtcars.csv", separator = ",")
EOF
      echo "      res1 = write_csv(raw_data, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(raw_data))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  summary_jl = stdenv.mkDerivation {
    name = "summary_jl";
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
      summary_jl = jln(command = using DataFrames, Statistics
            # raw_data is available as a DataFrame thanks to automatic CSV deserialization
            gdf = groupby(raw_data, :cyl)
            combine(gdf, :mpg => mean => :avg_mpg), deserializer = ^csv, serializer = ^csv)
EOF
      echo "      res1 = serialize(summary_jl, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(summary_jl))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  final_results = stdenv.mkDerivation {
    name = "final_results";
    buildInputs = [ tBin summary_jl ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_summary_jl = summary_jl;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_summary_jl=${summary_jl}

      cat << EOF > node_script.t
EOF











      echo "summary_jl = read_csv(\"$T_NODE_summary_jl/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      final_results = summary_jl
EOF
      echo "      res1 = serialize(final_results, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(final_results))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin raw_data summary_jl final_results ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw_data} $out/raw_data
      cp -r ${summary_jl} $out/summary_jl
      cp -r ${final_results} $out/final_results
    '';
  };
}

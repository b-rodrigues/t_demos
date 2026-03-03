
{ system ? builtins.currentSystem }:
let
  # Pull exact pinned inputs from the project flake.
  # The flake.lock guarantees reproducibility.
  # Note: toString is required to convert the path to a string
  # that builtins.getFlake accepts.
  flake  = builtins.getFlake (toString ../.);
  pkgs   = flake.inputs.nixpkgs.legacyPackages.${system};
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
    ./..;

  toml = if builtins.pathExists ../tproject.toml then builtins.fromTOML (builtins.readFile ../tproject.toml) else {};
  
  rPackagesList = toml.r-dependencies.packages or [];
  r-env = pkgs.rWrapper.override {
    packages = (builtins.map (p: pkgs.rPackages.${p}) rPackagesList) ++ [ pkgs.rPackages.jsonlite ];
  };

  pyDeps = toml.py-dependencies or toml.python-dependencies or {};
  pyVersion = pyDeps.version or "python3";
  pyPackagesList = pyDeps.packages or [];
  py-env = pkgs.${pyVersion}.withPackages (ps: (builtins.map (p: ps.${p}) pyPackagesList));
in
rec {

  mtcars = stdenv.mkDerivation {
    name = "mtcars";
    buildInputs = [ tBin  ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.t
EOF







      cat <<'EOF' >> node_script.t
      mtcars = read_csv("data/mtcars.csv", separator = "|")
EOF
      echo "      res1 = serialize(mtcars, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(mtcars))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe node_script.t
    '';
  };


  filtered_mtcars = stdenv.mkDerivation {
    name = "filtered_mtcars";
    buildInputs = [ tBin mtcars ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_mtcars=${mtcars}

      cat << EOF > node_script.t
EOF






      echo "mtcars = deserialize(\"$T_NODE_mtcars/artifact\")" >> node_script.t
      cat <<'EOF' >> node_script.t
      filtered_mtcars = (mtcars |> filter(($am == 1)))
EOF
      echo "      res1 = serialize(filtered_mtcars, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(filtered_mtcars))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe node_script.t
    '';
  };


  mtcars_mpg = stdenv.mkDerivation {
    name = "mtcars_mpg";
    buildInputs = [ tBin filtered_mtcars ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_filtered_mtcars=${filtered_mtcars}

      cat << EOF > node_script.t
EOF






      echo "filtered_mtcars = deserialize(\"$T_NODE_filtered_mtcars/artifact\")" >> node_script.t
      cat <<'EOF' >> node_script.t
      mtcars_mpg = (filtered_mtcars |> select($mpg))
EOF
      echo "      res1 = serialize(mtcars_mpg, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(mtcars_mpg))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe node_script.t
    '';
  };

  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin mtcars filtered_mtcars mtcars_mpg ];
    buildCommand = ''
      mkdir -p $out
      cp -r ${mtcars} $out/mtcars
      cp -r ${filtered_mtcars} $out/filtered_mtcars
      cp -r ${mtcars_mpg} $out/mtcars_mpg
    '';
  };
}


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

  raw_data = stdenv.mkDerivation {
    name = "raw_data";
    buildInputs = [ tBin r-env ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .

      cat << EOF > node_script.R
EOF

      cat << 'EOF' >> node_script.R

t_write_csv <- function(object, path) {
  if (inherits(object, "data.frame")) {
    write.csv(object, path, row.names = FALSE)
  } else {
    write.csv(as.data.frame(object), path, row.names = FALSE)
  }
}
t_read_csv <- function(path) {
  read.csv(path, stringsAsFactors = FALSE)
}

EOF





      cat <<'EOF' >> node_script.R
library(datasets)
EOF


      echo "raw_data <- local({" >> node_script.R
      cat <<'EOF' >> node_script.R
      data(mtcars)
      mtcars
EOF
      echo "})" >> node_script.R
      echo "t_write_csv(raw_data, \"$out/artifact\")" >> node_script.R
      echo "writeLines(as.character(class(raw_data)[1]), \"$out/class\")" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };


  r_model = stdenv.mkDerivation {
    name = "r_model";
    buildInputs = [ tBin r-env raw_data ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.R
EOF
      cat << 'EOF' >> node_script.R

t_write_json <- function(object, path) {
  jsonlite::write_json(object, path, auto_unbox = TRUE, null = "null")
}
t_read_json <- function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
}

EOF







      echo "raw_data <- readRDS(\"$T_NODE_raw_data/artifact\")" >> node_script.R
      echo "r_model <- local({" >> node_script.R
      cat <<'EOF' >> node_script.R
model = lm(mpg ~ hp, data = raw_data)
      summary(model)$r.squared
EOF
      echo "})" >> node_script.R
      echo "t_write_json(r_model, \"$out/artifact\")" >> node_script.R
      echo "writeLines(as.character(class(r_model)[1]), \"$out/class\")" >> node_script.R
      mkdir -p $out
      Rscript node_script.R
    '';
  };


  py_model = stdenv.mkDerivation {
    name = "py_model";
    buildInputs = [ tBin py-env raw_data ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_raw_data=${raw_data}

      cat << EOF > node_script.py
EOF
      cat << 'EOF' >> node_script.py

import json
def t_write_json(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f)
def t_read_json(path):
    with open(path) as f:
        return json.load(f)

EOF



      cat << 'EOF' >> node_script.py

import pickle
def serialize(obj, path):
    with open(path, "wb") as f:
        pickle.dump(obj, f)
def deserialize(path):
    with open(path, "rb") as f:
        return pickle.load(f)

EOF


      cat <<'EOF' >> node_script.py
from sklearn.ensemble import RandomForestRegressor
import pandas as pd
EOF

      echo "raw_data = deserialize(\"$T_NODE_raw_data/artifact\")" >> node_script.py
      cat <<'EOF' >> node_script.py
py_model = (      X = raw_data[['hp', 'wt']]
      y = raw_data['mpg']
      rf = RandomForestRegressor(n_estimators=10)
      rf.fit(X, y)
      rf.score(X, y) -- Returns R^2)
EOF
      echo "t_write_json(py_model, \"$out/artifact\")" >> node_script.py
      echo "with open(\"$out/class\", \"w\") as f: f.write(type(py_model).__name__)" >> node_script.py
      mkdir -p $out
      python node_script.py
    '';
  };


  compare = stdenv.mkDerivation {
    name = "compare";
    buildInputs = [ tBin py_model r_model ];
    T_JPMML_STATSMODELS_JAR = "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar";
    src = sources;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_py_model=${py_model}
      export T_NODE_r_model=${r_model}

      cat << EOF > node_script.t
EOF








      echo "py_model = deserialize(\"$T_NODE_py_model/artifact\")" >> node_script.t
      echo "r_model = deserialize(\"$T_NODE_r_model/artifact\")" >> node_script.t
      cat <<'EOF' >> node_script.t
      compare = null
EOF
      echo "      res1 = serialize(compare, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(compare))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe node_script.t
    '';
  };

  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin raw_data r_model py_model compare ];
    buildCommand = ''
      mkdir -p $out
      cp -r ${raw_data} $out/raw_data
      cp -r ${r_model} $out/r_model
      cp -r ${py_model} $out/py_model
      cp -r ${compare} $out/compare
    '';
  };
}

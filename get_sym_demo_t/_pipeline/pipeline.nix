
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

  my_var = stdenv.mkDerivation {
    name = "my_var";
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
      my_var = 42
EOF
      echo "      res1 = serialize(my_var, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(my_var))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  var_name = stdenv.mkDerivation {
    name = "var_name";
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
      var_name = "my_var"
EOF
      echo "      res1 = serialize(var_name, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(var_name))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val1 = stdenv.mkDerivation {
    name = "val1";
    buildInputs = [ tBin my_var ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_my_var = my_var;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_var=${my_var}

      cat << EOF > node_script.t
EOF











      echo "my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      val1 = get("my_var")
EOF
      echo "      res1 = serialize(val1, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(val1))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val1 = stdenv.mkDerivation {
    name = "test_val1";
    buildInputs = [ tBin val1 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_val1 = val1;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val1=${val1}

      cat << EOF > node_script.t
EOF











      echo "val1 = deserialize(\"$T_NODE_val1/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_val1 = assert((val1 == 42))
EOF
      echo "      res1 = serialize(test_val1, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_val1))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val2 = stdenv.mkDerivation {
    name = "val2";
    buildInputs = [ tBin my_var var_name ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_my_var = my_var;
    T_NODE_var_name = var_name;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_var=${my_var}
      export T_NODE_var_name=${var_name}

      cat << EOF > node_script.t
EOF











      echo "my_var = deserialize(\"$T_NODE_my_var/artifact\")" >> node_script.t
      echo "var_name = deserialize(\"$T_NODE_var_name/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      val2 = get(to_symbol(var_name))
EOF
      echo "      res1 = serialize(val2, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(val2))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val2 = stdenv.mkDerivation {
    name = "test_val2";
    buildInputs = [ tBin val2 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_val2 = val2;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val2=${val2}

      cat << EOF > node_script.t
EOF











      echo "val2 = deserialize(\"$T_NODE_val2/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_val2 = assert((val2 == 42))
EOF
      echo "      res1 = serialize(test_val2, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_val2))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  my_list = stdenv.mkDerivation {
    name = "my_list";
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
      my_list = [10, 20, 30, 40]
EOF
      echo "      res1 = serialize(my_list, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(my_list))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val3 = stdenv.mkDerivation {
    name = "val3";
    buildInputs = [ tBin my_list ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_my_list = my_list;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_my_list=${my_list}

      cat << EOF > node_script.t
EOF











      echo "my_list = deserialize(\"$T_NODE_my_list/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      val3 = get(my_list, 2)
EOF
      echo "      res1 = serialize(val3, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(val3))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val3 = stdenv.mkDerivation {
    name = "test_val3";
    buildInputs = [ tBin val3 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_val3 = val3;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val3=${val3}

      cat << EOF > node_script.t
EOF











      echo "val3 = deserialize(\"$T_NODE_val3/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_val3 = assert((val3 == 30))
EOF
      echo "      res1 = serialize(test_val3, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_val3))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_a = stdenv.mkDerivation {
    name = "node_a";
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
      node_a = 100
EOF
      echo "      res1 = t_write_json(node_a, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(node_a))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  node_b = stdenv.mkDerivation {
    name = "node_b";
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
      node_b = 200
EOF
      echo "      res1 = t_write_json(node_b, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(node_b))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  dynamic_access = stdenv.mkDerivation {
    name = "dynamic_access";
    buildInputs = [ tBin node_a node_b ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_node_a = node_a;
    T_NODE_node_b = node_b;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_node_a=${node_a}
      export T_NODE_node_b=${node_b}

      cat << EOF > node_script.t
EOF











      echo "node_a = t_read_json(\"$T_NODE_node_a/artifact\")" >> node_script.t
      echo "node_b = t_read_json(\"$T_NODE_node_b/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      dynamic_access = { target = "node_a"; get(node_lens(target)) }
EOF
      echo "      res1 = serialize(dynamic_access, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(dynamic_access))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_dynamic = stdenv.mkDerivation {
    name = "test_dynamic";
    buildInputs = [ tBin dynamic_access ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_dynamic_access = dynamic_access;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_dynamic_access=${dynamic_access}

      cat << EOF > node_script.t
EOF











      echo "dynamic_access = deserialize(\"$T_NODE_dynamic_access/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_dynamic = assert((dynamic_access == 100))
EOF
      echo "      res1 = serialize(test_dynamic, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_dynamic))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  target_col = stdenv.mkDerivation {
    name = "target_col";
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
      target_col = "mpg"
EOF
      echo "      res1 = serialize(target_col, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(target_col))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  s = stdenv.mkDerivation {
    name = "s";
    buildInputs = [ tBin target_col ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_target_col = target_col;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_target_col=${target_col}

      cat << EOF > node_script.t
EOF











      echo "target_col = deserialize(\"$T_NODE_target_col/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      s = to_symbol(target_col)
EOF
      echo "      res1 = serialize(s, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(s))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_sym = stdenv.mkDerivation {
    name = "test_sym";
    buildInputs = [ tBin s ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_s = s;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_s=${s}

      cat << EOF > node_script.t
EOF











      echo "s = deserialize(\"$T_NODE_s/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_sym = assert((type(s) == "Symbol"))
EOF
      echo "      res1 = serialize(test_sym, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_sym))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  my_dict = stdenv.mkDerivation {
    name = "my_dict";
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
      my_dict = [a: 1, b: 2]
EOF
      echo "      res1 = serialize(my_dict, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(my_dict))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  l = stdenv.mkDerivation {
    name = "l";
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
      l = col_lens("b")
EOF
      echo "      res1 = serialize(l, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(l))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  val4 = stdenv.mkDerivation {
    name = "val4";
    buildInputs = [ tBin l my_dict ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_l = l;
    T_NODE_my_dict = my_dict;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_l=${l}
      export T_NODE_my_dict=${my_dict}

      cat << EOF > node_script.t
EOF











      echo "l = deserialize(\"$T_NODE_l/artifact\")" >> node_script.t
      echo "my_dict = deserialize(\"$T_NODE_my_dict/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      val4 = get(my_dict, l)
EOF
      echo "      res1 = serialize(val4, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(val4))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  test_val4 = stdenv.mkDerivation {
    name = "test_val4";
    buildInputs = [ tBin val4 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_val4 = val4;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_val4=${val4}

      cat << EOF > node_script.t
EOF











      echo "val4 = deserialize(\"$T_NODE_val4/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      test_val4 = assert((val4 == 2))
EOF
      echo "      res1 = serialize(test_val4, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(test_val4))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  all_passed = stdenv.mkDerivation {
    name = "all_passed";
    buildInputs = [ tBin test_dynamic test_sym test_val1 test_val2 test_val3 test_val4 ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_test_dynamic = test_dynamic;
    T_NODE_test_sym = test_sym;
    T_NODE_test_val1 = test_val1;
    T_NODE_test_val2 = test_val2;
    T_NODE_test_val3 = test_val3;
    T_NODE_test_val4 = test_val4;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_test_dynamic=${test_dynamic}
      export T_NODE_test_sym=${test_sym}
      export T_NODE_test_val1=${test_val1}
      export T_NODE_test_val2=${test_val2}
      export T_NODE_test_val3=${test_val3}
      export T_NODE_test_val4=${test_val4}

      cat << EOF > node_script.t
EOF











      echo "test_dynamic = deserialize(\"$T_NODE_test_dynamic/artifact\")" >> node_script.t
      echo "test_sym = deserialize(\"$T_NODE_test_sym/artifact\")" >> node_script.t
      echo "test_val1 = deserialize(\"$T_NODE_test_val1/artifact\")" >> node_script.t
      echo "test_val2 = deserialize(\"$T_NODE_test_val2/artifact\")" >> node_script.t
      echo "test_val3 = deserialize(\"$T_NODE_test_val3/artifact\")" >> node_script.t
      echo "test_val4 = deserialize(\"$T_NODE_test_val4/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      all_passed = assert((((((test_val1 && test_val2) && test_val3) && test_dynamic) && test_sym) && test_val4))
EOF
      echo "      res1 = serialize(all_passed, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(all_passed))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin my_var var_name val1 test_val1 val2 test_val2 my_list val3 test_val3 node_a node_b dynamic_access test_dynamic target_col s test_sym my_dict l val4 test_val4 all_passed ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${my_var} $out/my_var
      cp -r ${var_name} $out/var_name
      cp -r ${val1} $out/val1
      cp -r ${test_val1} $out/test_val1
      cp -r ${val2} $out/val2
      cp -r ${test_val2} $out/test_val2
      cp -r ${my_list} $out/my_list
      cp -r ${val3} $out/val3
      cp -r ${test_val3} $out/test_val3
      cp -r ${node_a} $out/node_a
      cp -r ${node_b} $out/node_b
      cp -r ${dynamic_access} $out/dynamic_access
      cp -r ${test_dynamic} $out/test_dynamic
      cp -r ${target_col} $out/target_col
      cp -r ${s} $out/s
      cp -r ${test_sym} $out/test_sym
      cp -r ${my_dict} $out/my_dict
      cp -r ${l} $out/l
      cp -r ${val4} $out/val4
      cp -r ${test_val4} $out/test_val4
      cp -r ${all_passed} $out/all_passed
    '';
  };
}

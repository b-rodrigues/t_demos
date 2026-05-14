
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

  source_csv = stdenv.mkDerivation {
    name = "source_csv";
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








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t




      echo "      source_csv = {" >> node_script.t
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
            csv_path = "arrow_source_coverage_seed.csv"
            res_w = write_csv(seed, csv_path)
            print("Write result:")
            print(res_w)
            read_csv(csv_path)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(source_csv, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(source_csv))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  arrow_roundtrip = stdenv.mkDerivation {
    name = "arrow_roundtrip";
    buildInputs = [ tBin source_csv ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_source_csv = source_csv;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_source_csv=${source_csv}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "source_csv = read_arrow(\"$T_NODE_source_csv/artifact\")" >> node_script.t

      echo "      arrow_roundtrip = {" >> node_script.t
      cat <<'EOF' >> node_script.t
arrow_path = "arrow_source_coverage.arrow"
            write_arrow(source_csv, arrow_path)
            read_arrow(arrow_path)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(arrow_roundtrip, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(arrow_roundtrip))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  compute_features = stdenv.mkDerivation {
    name = "compute_features";
    buildInputs = [ tBin arrow_roundtrip ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_arrow_roundtrip = arrow_roundtrip;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_arrow_roundtrip=${arrow_roundtrip}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "arrow_roundtrip = read_arrow(\"$T_NODE_arrow_roundtrip/artifact\")" >> node_script.t

      echo "      compute_features = {" >> node_script.t
      cat <<'EOF' >> node_script.t
arrow_roundtrip
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
      echo "      res1 = write_arrow(compute_features, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(compute_features))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      top_slice = ((compute_features |> arrange($amount, direction = "desc")) |> slice([0, 1, 2]))
EOF
      echo "      res1 = write_arrow(top_slice, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(top_slice))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      active_projection = ((compute_features |> filter($flag)) |> select($id, $segment, $amount, $net, $stage))
EOF
      echo "      res1 = write_arrow(active_projection, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(active_projection))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      segment_counts = count(compute_features, $segment)
EOF
      echo "      res1 = write_arrow(segment_counts, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(segment_counts))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      grouped_summary = ((((compute_features |> mutate(stage_s = to_string($stage))) |> group_by($segment)) |> summarize(avg_amount = mean($amount), min_amount = min($amount), max_amount = max($amount), unique_stages = n_distinct($stage_s), total_bonus = sum($bonus, na_rm = true), last_running = max($running_amount))) |> arrange($segment))
EOF
      echo "      res1 = write_arrow(grouped_summary, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(grouped_summary))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      aggregate_snapshot = (compute_features |> summarize(min_amount = min($amount), max_amount = max($amount), unique_segments = n_distinct($segment), avg_exp_offset = mean($exp_offset)))
EOF
      echo "      res1 = write_arrow(aggregate_snapshot, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(aggregate_snapshot))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      nested_groups = ((compute_features |> group_by($segment)) |> nest())
EOF
      echo "      res1 = serialize(nested_groups, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(nested_groups))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_nested_groups = nested_groups;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_nested_groups=${nested_groups}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "nested_groups = deserialize(\"$T_NODE_nested_groups/artifact\")" >> node_script.t

      cat <<'EOF' >> node_script.t
      roundtrip_nested = ((nested_groups |> unnest($data)) |> arrange($id))
EOF
      echo "      res1 = write_arrow(roundtrip_nested, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(roundtrip_nested))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_diagnostics = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(model, data = compute_features)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_diagnostics, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_diagnostics))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_predictions = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            predict(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = serialize(model_predictions, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_predictions))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_augmented = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            add_diagnostics(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_augmented, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_augmented))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_residuals = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            residuals(compute_features, model)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_residuals, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_residuals))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_coefficients = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            coef(model)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_coefficients, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_coefficients))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_confidence = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            conf_int(model)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_confidence, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_confidence))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_fit_stats = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            fit_stats([reduced: reduced, full: full])
EOF
      echo "      }" >> node_script.t
      echo "      res1 = serialize(model_fit_stats, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_fit_stats))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_anova = {" >> node_script.t
      cat <<'EOF' >> node_script.t
reduced = lm(data = compute_features, formula = amount ~ offset)
            full = lm(data = compute_features, formula = amount ~ offset + stage)
            anova(reduced, full)
EOF
      echo "      }" >> node_script.t
      echo "      res1 = write_arrow(model_anova, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_anova))" >> node_script.t
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
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_compute_features = compute_features;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_compute_features=${compute_features}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t

      echo "      model_wald = {" >> node_script.t
      cat <<'EOF' >> node_script.t
model = lm(data = compute_features, formula = amount ~ offset + stage)
            wald_test(model, terms = ["offset"])
EOF
      echo "      }" >> node_script.t
      echo "      res1 = serialize(model_wald, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(model_wald))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 

  validation_report = stdenv.mkDerivation {
    name = "validation_report";
    buildInputs = [ tBin active_projection aggregate_snapshot arrow_roundtrip compute_features grouped_summary model_anova model_augmented model_coefficients model_confidence model_diagnostics model_fit_stats model_predictions model_residuals model_wald roundtrip_nested segment_counts source_csv top_slice ] ++ globalBuildInputs;
    T_JPMML_STATSMODELS_JAR = if (pkgs ? jpmml-statsmodels) then "${pkgs.jpmml-statsmodels}/share/java/jpmml-statsmodels.jar" else "";
    T_JPMML_EVALUATOR_JAR = if (pkgs ? jpmml-evaluator) then "${pkgs.jpmml-evaluator}/share/java/jpmml-evaluator.jar" else "";
    MPLCONFIGDIR = ".";
    src = sources;

    T_NODE_active_projection = active_projection;
    T_NODE_aggregate_snapshot = aggregate_snapshot;
    T_NODE_arrow_roundtrip = arrow_roundtrip;
    T_NODE_compute_features = compute_features;
    T_NODE_grouped_summary = grouped_summary;
    T_NODE_model_anova = model_anova;
    T_NODE_model_augmented = model_augmented;
    T_NODE_model_coefficients = model_coefficients;
    T_NODE_model_confidence = model_confidence;
    T_NODE_model_diagnostics = model_diagnostics;
    T_NODE_model_fit_stats = model_fit_stats;
    T_NODE_model_predictions = model_predictions;
    T_NODE_model_residuals = model_residuals;
    T_NODE_model_wald = model_wald;
    T_NODE_roundtrip_nested = roundtrip_nested;
    T_NODE_segment_counts = segment_counts;
    T_NODE_source_csv = source_csv;
    T_NODE_top_slice = top_slice;
    buildCommand = ''
      cp -r $src/* . || true
      chmod -R u+w .
      export T_NODE_active_projection=${active_projection}
      export T_NODE_aggregate_snapshot=${aggregate_snapshot}
      export T_NODE_arrow_roundtrip=${arrow_roundtrip}
      export T_NODE_compute_features=${compute_features}
      export T_NODE_grouped_summary=${grouped_summary}
      export T_NODE_model_anova=${model_anova}
      export T_NODE_model_augmented=${model_augmented}
      export T_NODE_model_coefficients=${model_coefficients}
      export T_NODE_model_confidence=${model_confidence}
      export T_NODE_model_diagnostics=${model_diagnostics}
      export T_NODE_model_fit_stats=${model_fit_stats}
      export T_NODE_model_predictions=${model_predictions}
      export T_NODE_model_residuals=${model_residuals}
      export T_NODE_model_wald=${model_wald}
      export T_NODE_roundtrip_nested=${roundtrip_nested}
      export T_NODE_segment_counts=${segment_counts}
      export T_NODE_source_csv=${source_csv}
      export T_NODE_top_slice=${top_slice}

      cat << EOF > node_script.t
EOF








      echo 'import dataframe' >> node_script.t
      echo 'import colcraft' >> node_script.t
      echo 'import stats' >> node_script.t
      echo 'import math' >> node_script.t


      echo "active_projection = read_arrow(\"$T_NODE_active_projection/artifact\")" >> node_script.t
      echo "aggregate_snapshot = read_arrow(\"$T_NODE_aggregate_snapshot/artifact\")" >> node_script.t
      echo "arrow_roundtrip = read_arrow(\"$T_NODE_arrow_roundtrip/artifact\")" >> node_script.t
      echo "compute_features = read_arrow(\"$T_NODE_compute_features/artifact\")" >> node_script.t
      echo "grouped_summary = read_arrow(\"$T_NODE_grouped_summary/artifact\")" >> node_script.t
      echo "model_anova = read_arrow(\"$T_NODE_model_anova/artifact\")" >> node_script.t
      echo "model_augmented = read_arrow(\"$T_NODE_model_augmented/artifact\")" >> node_script.t
      echo "model_coefficients = read_arrow(\"$T_NODE_model_coefficients/artifact\")" >> node_script.t
      echo "model_confidence = read_arrow(\"$T_NODE_model_confidence/artifact\")" >> node_script.t
      echo "model_diagnostics = read_arrow(\"$T_NODE_model_diagnostics/artifact\")" >> node_script.t
      echo "model_fit_stats = deserialize(\"$T_NODE_model_fit_stats/artifact\")" >> node_script.t
      echo "model_predictions = deserialize(\"$T_NODE_model_predictions/artifact\")" >> node_script.t
      echo "model_residuals = read_arrow(\"$T_NODE_model_residuals/artifact\")" >> node_script.t
      echo "model_wald = deserialize(\"$T_NODE_model_wald/artifact\")" >> node_script.t
      echo "roundtrip_nested = read_arrow(\"$T_NODE_roundtrip_nested/artifact\")" >> node_script.t
      echo "segment_counts = read_arrow(\"$T_NODE_segment_counts/artifact\")" >> node_script.t
      echo "source_csv = read_arrow(\"$T_NODE_source_csv/artifact\")" >> node_script.t
      echo "top_slice = read_arrow(\"$T_NODE_top_slice/artifact\")" >> node_script.t

      echo "      validation_report = {" >> node_script.t
      cat <<'EOF' >> node_script.t
assert(nrow(source_csv) == 6, "CSV roundtrip should preserve all rows")
            assert(get(pull(arrow_roundtrip, $note), 0) == "alpha,beta", "CSV quoting should roundtrip commas")
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
      echo "      res1 = serialize(validation_report, \"$out/artifact\")" >> node_script.t
      echo "      if (is_error(res1)) { print(\"Serialization failed:\"); print(res1); exit(1) } else { 0 }" >> node_script.t
      echo "      res2 = write_text(\"$out/class\", type(validation_report))" >> node_script.t
      echo "      if (is_error(res2)) { print(\"Class write failed:\"); print(res2); exit(1) } else { 0 }" >> node_script.t
      mkdir -p $out
      t run --unsafe --mode repl node_script.t
    '';
  };
 
  pipeline_output = stdenv.mkDerivation {
    name = "pipeline_output";
    buildInputs = [ tBin source_csv arrow_roundtrip compute_features top_slice active_projection segment_counts grouped_summary aggregate_snapshot nested_groups roundtrip_nested model_diagnostics model_predictions model_augmented model_residuals model_coefficients model_confidence model_fit_stats model_anova model_wald validation_report ] ++ globalBuildInputs;
    buildCommand = ''
      mkdir -p $out
      cp -r ${source_csv} $out/source_csv
      cp -r ${arrow_roundtrip} $out/arrow_roundtrip
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

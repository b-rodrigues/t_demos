{
  description = "quarto_latex_demo — a T data analysis project";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-04-02";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "path:/home/brodrigues/Documents/repos/tlang";
  };

  nixConfig = {
    extra-substituters = [
      "https://rstats-on-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
  };

  outputs = { self, nixpkgs, flake-utils, t-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # R environment
        r-env = pkgs.rWrapper.override {
          packages = with pkgs.rPackages; [
            ggplot2
            jsonlite
            knitr
            rmarkdown
          ];
        };

        # Python environment
        py-env = pkgs.python3.withPackages (ps: with ps; [
          pandas
          numpy
          ipykernel
          nbclient
          nbformat
          pyyaml
        ]);

        # Julia environment
        julia-env = pkgs.julia.withPackages [
          "DataFrames"
          "CSV"
          "JSON"
        ];

        # Additional Tools
        additionalTools = with pkgs; [
          quarto
          texliveFull
          which
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
            r-env
            py-env
            julia-env
          ] ++ additionalTools;

          shellHook = ''
            echo "=================================================="
            echo "T Project: quarto_latex_demo"
            echo "=================================================="
            echo ""
            
            mkdir -p _extensions
            expected_quarto_ext="${t-lang.packages.${system}.default}/share/tlang/quarto/tlang"
            quarto_ext_path="_extensions/tlang"
            if [ -d "$expected_quarto_ext" ]; then
              rm -rf "$quarto_ext_path"
              mkdir -p "$quarto_ext_path"
              cp -R "$expected_quarto_ext"/. "$quarto_ext_path"/
              echo "✓ T Quarto extension provisioned."
            fi
          '';
        };

        packages.default = t-lang.packages.${system}.default;
      }
    );
}

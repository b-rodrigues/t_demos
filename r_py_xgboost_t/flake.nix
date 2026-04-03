{
  description = "XGBoost Polyglot T Demo";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-04-02";
    t-lang.url = "git+file:///home/brodrigues/Documents/repos/tlang";
  };

  # Configure cachix for R packages
  nixConfig = {
    extra-substituters = [
      "https://rstats-on-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
  };

  outputs = { self, nixpkgs, t-lang }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      tBin = t-lang.packages.${system}.default;
      
      r-env = pkgs.rWrapper.override {
        packages = with pkgs.rPackages; [ dplyr yardstick arrow ];
      };
      
      py-env = pkgs.python3.withPackages (ps: with ps; [ numpy pandas scikit-learn xgboost pyarrow ]);
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ tBin r-env py-env pkgs.quarto pkgs.which ];
        shellHook = ''
          export TLANG_REPO_ROOT="/home/brodrigues/Documents/repos/tlang"
          alias t='${tBin}/bin/t'
        '';
      };
      
      packages.${system}.default = pkgs.stdenv.mkDerivation {
         name = "demo";
         src = ./.;
         buildInputs = [ tBin r-env py-env pkgs.quarto pkgs.which ];
         installPhase = "mkdir -p $out; cp -r * $out/";
      };
    };
}

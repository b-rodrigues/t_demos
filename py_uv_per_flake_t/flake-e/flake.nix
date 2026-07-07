{
  description = "nixpkgs 24.11 with numpy for per-flake Python node e";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = builtins.currentSystem;
    pkgs = nixpkgs.legacyPackages.${system};
    pyVersion = "python312";
  in {
    packages.${system} = {
      py-env = pkgs.${pyVersion}.withPackages (ps: [ ps.numpy ]);
    };
  };
}

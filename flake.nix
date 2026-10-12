{
  description = "Greed: a modal text editor with Helix, Vim and VS Code keys and Luau plugins";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Built packages, for main and every release, so they download.
  nixConfig = {
    extra-substituters = [ "https://greed.cachix.org" ];
    extra-trusted-public-keys = [
      "greed.cachix.org-1:3KCJ/GtSbnfcfrCNZAe+3vcK8YPc4FZ/2JaYTjAqmnc="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config = { };
              overlays = [ ];
            }
          )
        );
    in
    {
      # `nix run github:OWNER/greed`, with the window; `.#static` is one
      # statically linked binary for the terminal (Linux, musl).
      packages = forSystems (
        pkgs:
        {
          default = pkgs.callPackage ./nix/package.nix { };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          static = pkgs.pkgsStatic.callPackage ./nix/package.nix { };
        }
      );

      overlays.default = final: _prev: {
        greed = final.callPackage ./nix/package.nix { };
      };
    };
}

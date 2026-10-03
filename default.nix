# `nix-build` builds Greed; `nix-build -A static` builds one statically
# linked binary (Linux, musl) that runs on any Linux of the same CPU.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.callPackage ./nix/package.nix { }
// {
  static = pkgs.pkgsStatic.callPackage ./nix/package.nix { };
}

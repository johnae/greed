# Kern as a Nix package: `pkgs.callPackage ./nix/package.nix { }`.
{
  lib,
  stdenv,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "kern";
  version = (lib.importTOML ../Cargo.toml).workspace.package.version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../crates
      ../runtime
      ../vendor
    ];
  };

  cargoLock.lockFile = ../Cargo.lock;

  # A static binary is linked without PIE: the static C++ library Luau
  # links against isn't built position-independent.
  env = lib.optionalAttrs stdenv.hostPlatform.isStatic {
    RUSTFLAGS = "-C relocation-model=static";
  };
  cargoBuildFlags = [ "--package" "kern" ];

  # The runtime is built into the binary too; installing it lets editors
  # find the Luau types for plugins.
  postInstall = ''
    mkdir -p $out/share/kern
    cp -r runtime $out/share/kern/runtime
  '';

  # The tests need luau-analyze, a terminal and sockets; run them with cargo.
  doCheck = false;

  meta = {
    description = "A fast, extensible modal editor with a Luau plugin layer";
    mainProgram = "kern";
    platforms = lib.platforms.unix;
  };
}

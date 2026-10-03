# Greed as a Nix package: `pkgs.callPackage ./nix/package.nix { }`.
{
  lib,
  stdenv,
  rustPlatform,
  cmake,
}:

rustPlatform.buildRustPackage {
  pname = "greed";
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

  # wasmtime, which loads downloaded grammars, builds its C API with cmake;
  # it runs cmake itself, so the usual cmake configure step stays out.
  nativeBuildInputs = [ cmake ];
  dontUseCmakeConfigure = true;

  # A static binary is linked without PIE: the static C++ library Luau
  # links against isn't built position-independent.
  env = lib.optionalAttrs stdenv.hostPlatform.isStatic {
    RUSTFLAGS = "-C relocation-model=static";
  };
  cargoBuildFlags = [ "--package" "greed-editor" ];

  # The runtime is built into the binary too; installing it lets editors
  # find the Luau types for plugins.
  postInstall = ''
    mkdir -p $out/share/greed
    cp -r runtime $out/share/greed/runtime
  '';

  # The tests need luau-analyze, a terminal and sockets; run them with cargo.
  doCheck = false;

  meta = {
    description = "A General Runtime for Editing, Extending and Delegating: an extensible editor and more";
    mainProgram = "greed";
    platforms = lib.platforms.unix;
  };
}

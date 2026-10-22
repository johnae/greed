# Greed as a Nix package: `pkgs.callPackage ./nix/package.nix { }`.
{
  lib,
  stdenv,
  rustPlatform,
  cmake,
  makeWrapper,
  libGL,
  libxkbcommon,
  vulkan-loader,
  wayland,
  xorg,
}:

let
  # The window client, `greed --gui`, stays out of the static build that
  # runs on servers.
  gui = !stdenv.hostPlatform.isStatic;
  # What the window loads at run time on Linux: the display server's
  # libraries and the GPU driver's loader.
  guiLibraries = [
    libGL
    libxkbcommon
    vulkan-loader
    wayland
    xorg.libX11
    xorg.libXcursor
    xorg.libXi
    xorg.libXrandr
  ];
in
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
      ../dist/greed-link.desktop
    ];
  };

  cargoLock.lockFile = ../Cargo.lock;

  # wasmtime, which loads downloaded grammars, builds its C API with cmake;
  # it runs cmake itself, so the usual cmake configure step stays out.
  nativeBuildInputs = [ cmake ] ++ lib.optional (gui && stdenv.hostPlatform.isLinux) makeWrapper;
  dontUseCmakeConfigure = true;

  # A static binary is linked without PIE: the static C++ library Luau
  # links against isn't built position-independent.
  env = lib.optionalAttrs stdenv.hostPlatform.isStatic {
    RUSTFLAGS = "-C relocation-model=static";
  };
  # The release profile with full link-time optimization (Cargo.toml).
  buildType = "dist";
  # Greed, and the programs its sessions run beside it: mail, and chat.
  cargoBuildFlags = [
    "--package"
    "greed-editor"
    "--package"
    "greed-mail"
    "--package"
    "greed-matrix"
    "--package"
    "greed-mattermost"
  ];
  buildNoDefaultFeatures = !gui;

  # The runtime is built into the binary too; installing it lets editors
  # find the Luau types for plugins.
  postInstall = ''
    mkdir -p $out/share/greed
    cp -r runtime $out/share/greed/runtime
    # Hands the browser's sign-in links back to the chat.
    install -Dm644 dist/greed-link.desktop -t $out/share/applications
  '';

  postFixup = lib.optionalString (gui && stdenv.hostPlatform.isLinux) ''
    wrapProgram $out/bin/greed --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath guiLibraries}
  '';

  # The tests need luau-analyze, a terminal and sockets; run them with cargo.
  doCheck = false;

  meta = {
    description = "Get, Reflect, Eval, Edit, Delegate: an execution environment with a good editor built in";
    mainProgram = "greed";
    platforms = lib.platforms.unix;
  };
}

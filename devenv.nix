{ pkgs, lib, ... }:

{
  languages.rust = {
    enable = true;
    toolchainFile = ./rust-toolchain.toml;
  };

  packages = [
    # Rust workflow
    pkgs.cargo-nextest
    pkgs.cargo-insta
    pkgs.cargo-deny
    pkgs.cargo-llvm-cov
    # Optional compile cache: `export RUSTC_WRAPPER=sccache`. It shares the
    # C and C++ parts (Luau, tree-sitter grammars, wasmtime) between
    # checkouts; Rust crates hit only when built at the same target path.
    pkgs.sccache
    # `script`, which the terminal tests run greed under
    pkgs.util-linux
    pkgs.bacon

    # Luau: runtime/analyzer, language server, formatter
    pkgs.luau
    pkgs.luau-lsp
    pkgs.stylua

    # Spelling and grammar for prose, through the lsp plugin
    pkgs.harper

    pkgs.tree-sitter
    # wasmtime, which loads downloaded grammars, builds its C API with it
    pkgs.cmake

    # The website: site/build.sh and site/serve.sh
    pkgs.mdbook
    pkgs.miniserve
  ];

  # What the window client (`greed --gui`) loads at run time: the display
  # server's libraries and the GPU driver's loader.
  env.LD_LIBRARY_PATH = lib.makeLibraryPath [
    pkgs.libGL
    pkgs.libxkbcommon
    pkgs.vulkan-loader
    pkgs.wayland
    pkgs.xorg.libX11
    pkgs.xorg.libXcursor
    pkgs.xorg.libXi
    pkgs.xorg.libXrandr
  ];

  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy = {
      enable = true;
      settings.denyWarnings = true;
    };
    stylua.enable = true;
  };

  # Run the hooks on commit, not every time the shell starts.
  tasks."devenv:git-hooks:run".before = lib.mkForce [ ];
}

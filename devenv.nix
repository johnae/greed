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
    # CHANGELOG.md from the commits (cliff.toml)
    pkgs.git-cliff
    # A real IMAP server for greed-mail's tests (crates/greed-mail/tests)
    pkgs.dovecot

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
    # Its videos: site/media/record.sh
    pkgs.ffmpeg-headless

    # An agent to try Greed's agent support with, beside Claude Code
    pkgs.opencode

    # The data plugin's sqlite source runs it, and its tests do
    pkgs.sqlite
  ]
  # Servers the chat programs' tests run against, which skip without them;
  # they don't build on macOS.
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    # A Matrix homeserver for greed-matrix's tests (crates/greed-matrix/tests)
    pkgs.matrix-tuwunel
  ];

  # What the window client (`greed --gui`) loads at run time: the display
  # server's libraries and the GPU driver's loader. macOS has them built in.
  env = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    LD_LIBRARY_PATH = lib.makeLibraryPath [
      pkgs.libGL
      pkgs.libxkbcommon
      pkgs.vulkan-loader
      pkgs.wayland
      pkgs.xorg.libX11
      pkgs.xorg.libXcursor
      pkgs.xorg.libXi
      pkgs.xorg.libXrandr
    ];
  };

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

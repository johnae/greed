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

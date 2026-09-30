{ pkgs, ... }:

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
    pkgs.bacon

    # Luau: runtime/analyzer, language server, formatter
    pkgs.luau
    pkgs.luau-lsp
    pkgs.stylua

    pkgs.tree-sitter
  ];

  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy = {
      enable = true;
      settings.denyWarnings = true;
    };
    stylua.enable = true;
  };
}

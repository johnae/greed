{ pkgs, ... }:

{
  languages.rust = {
    enable = true;
    toolchainFile = ./rust-toolchain.toml;
  };

  packages = with pkgs; [
    # Rust workflow
    cargo-nextest
    cargo-insta
    cargo-deny
    bacon

    # Luau: runtime/analyzer, language server, formatter
    luau
    luau-lsp
    stylua

    tree-sitter
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

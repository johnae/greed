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

  # Run the hooks on commit, not every time the shell starts.
  tasks."devenv:git-hooks:run".before = lib.mkForce [ ];
}

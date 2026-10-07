Greed is licensed under the Mozilla Public License 2.0 (see `LICENSE`).
Parts of it come from other projects, under their own licenses:

- `vendor/alacritty_terminal`: the terminal emulator from
  [Alacritty](https://github.com/alacritty/alacritty), Apache-2.0
  (`vendor/alacritty_terminal/LICENSE-APACHE`), with changes for Greed.
- `crates/greed-gui/fonts/SymbolsNerdFontMono-Regular.ttf`: the icons-only
  font from [Nerd Fonts](https://www.nerdfonts.com) 3.5.0, built into the
  window so icons show in any font, under the SIL Open Font License 1.1
  (`crates/greed-gui/fonts/OFL.txt`).
- `runtime/plugins/languages/queries/markdown_inline/highlights.scm`: adapted
  from [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter),
  Apache-2.0, with Greed's capture names.
- The other highlight and injection queries under
  `runtime/plugins/languages/queries` that say so in their first line come
  from the grammars' own repositories (tree-sitter-c, -go, -javascript,
  -json, -luau, -nix, -python, -rust, -toml, -typescript, -yaml), MIT, with
  Greed's capture names.

Rust dependencies keep their own licenses; `cargo deny check licenses`
(configured in `deny.toml`) checks that each is one Greed may use.

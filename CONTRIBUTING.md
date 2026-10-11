## Contributing

Issues and pull requests are welcome. For anything bigger than a fix, open
an issue first to talk it over: Greed has a strong opinion about where
things go, and it saves you rewriting.

That opinion: if it can be Luau, it's Luau. Rust holds what needs speed,
threads or the operating system, exposed as small, general primitives, and
modes, keymaps, commands, pickers and the agent protocols are plugins in
`runtime/plugins`. When adding a feature, look for the smallest Rust piece
that lets Luau do the rest. [How Greed is built](runtime/docs/design.md) says more.

### Building and checking

You need a recent stable Rust and cmake; `luau-analyze`, `luau-lsp` and
`stylua` for the Luau checks. With Nix, `devenv shell` has all of it.

Before sending a change, these should pass:

```bash
cargo fmt --check
cargo clippy -q --workspace --all-targets -- -D warnings
stylua --check runtime
cargo test -q --workspace
```

`cargo test` runs the Rust tests, every default plugin's Luau tests with
the others loaded, both Luau type checkers over the runtime, and the
performance budgets in `crates/greed-core/tests/budgets.rs`. A budget that
fails is a real slowdown to find. While working on a plugin,
`cargo build && ./target/debug/greed test runtime/plugins/NAME` runs just
its tests.

### Videos and screenshots

The demos for the docs and the website are scripts, `site/media/*.demo`:
keys to press, text to type and what to wait for, a step a line (the
recorder in `crates/greed-gui/src/record.rs` lists them).
`site/media/record.sh [NAME]` plays each one in a fresh Greed and draws
every frame as the window would, with no window, into `target/media/NAME`:
the screenshots the script takes, and `NAME.mp4` when ffmpeg is installed.
It needs a GPU, or software Vulkan like Mesa's lavapipe.

### Changes

- Write the test first where you can: Rust integration tests in
  `crates/greed-core/tests`, plugin tests in `runtime/plugins/*/test`.
- An API change updates `runtime/types/greed` (a test checks they match).
  Don't run stylua on `runtime/types/greed/init.luau`: a test reads one
  signature per line.
- A change users would notice updates `runtime/docs/` in the same commit.
- A change to what clients and sessions send each other that an older one
  would misread bumps `control::PROTOCOL`.
- Commits follow conventional commits, `type(scope): what it does`, kept
  short. Git or jj, either is fine.

By contributing, you agree that your work is licensed under the
[Mozilla Public License 2.0](LICENSE), like the rest of Greed.

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

### Keep it small

A PR I can read in one sitting gets in. One that changes 900 lines to add
an event probably doesn't, however good the idea - I can't tell what it
does to the rest. So:

- One change a PR. A fix found along the way is its own PR.
- The smallest diff that does it. Don't move, rename or reformat code
  you're not changing, and don't split a file to fix ten lines in it.
- Extend what's there before writing something new: an option on the
  existing function, not a second one that does nearly the same. If you
  find two copies, merge them. Look in `greed.*`, `core.*` and the plugin
  that owns the thing first.
- No machinery the change doesn't need: no extra checks "just in case", no
  provider or registry layers, no new abstraction for one caller.
- Don't change a default unless the issue asked for it.
- Don't touch `CHANGELOG.md`. It's written from the commits at release.
- Tests are short, one claim each, named as a sentence:
  `"a todo in a notes block is ticked from its row"`.
- Docs in plain words, where a user looks: settings in `using.md`, plugin
  APIs in `plugins.md`. A sentence or two is usually enough.
- The PR description says what and why in a few lines. Skip the
  validation logs - CI and the tests do that.

For a feature, open an issue with a sketch of the call first (a few lines
of Luau showing how you'd use it), and wait until we agree on the shape
before writing it.

Like these: [the sessions folder fix](https://github.com/johnae/greed/commit/ccca8be6)
and [waiting in tests](https://github.com/johnae/greed/commit/f6a28bb6), each
a few dozen lines with the test that shows it.

Using an agent is fine. Say so in the PR, make it read this file and
`AGENTS.md`, and read its diff yourself before you send it.

By contributing, you agree that your work is licensed under the
[Mozilla Public License 2.0](LICENSE), like the rest of Greed.

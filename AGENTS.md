# For coding agents

Read CONTRIBUTING.md first; this is the short version of what matters most.

- Make the smallest change that does what the issue asks. Nothing else.
- Don't move, rename, split or reformat code you aren't changing.
- Reuse what exists (`greed.*`, `core.*`, the owning plugin) instead of adding a
  near-copy. If it can be Luau, it's Luau; Rust only for speed, threads or the OS.
- No defensive checks, wrappers or registries the change doesn't need.
- Don't change defaults or behaviour the issue didn't ask about.
- Never edit CHANGELOG.md.
- Tests: short, one claim each, names are sentences. Update `runtime/types/greed`
  for API changes and `runtime/docs/` for what users notice.
- Before sending: `cargo fmt --check`, `cargo clippy -q --workspace --all-targets -- -D warnings`,
  `stylua --check runtime`, `cargo test -q --workspace`.
- PR description: what and why, a few lines. Say an agent wrote it.

If the diff is much bigger than the idea, stop and make it smaller.

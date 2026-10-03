# Greed

Greed, a General Runtime for Editing, Extending and Delegating, is a modal
editor for the terminal and the environment around it, with a small Rust
core and everything else in Luau plugins you can read, change or replace
while it runs. Agents use the editor through MCP, the shell and Claude Code's `/ide`,
and propose edits you review in the buffer.

- [Using Greed](using.md): editing, searching, files, sessions,
  configuration.
- [Writing plugins](plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](agents.md): `greed ctl`, MCP, proposals, `/ide` and plugins
  written by agents.
- [How Greed is built](design.md): what lives in Rust, what lives in Luau,
  and why.

These pages are plain Markdown, readable in a terminal or in Greed itself,
and `mdbook build docs` turns them into a website.

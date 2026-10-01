# Kern

Kern is a modal text editor for the terminal with a small Rust core and
everything else in Luau plugins you can read, change or replace while it
runs. Agents use the editor through MCP, the shell and Claude Code's `/ide`,
and propose edits you review in the buffer.

- [Using Kern](using.md): editing, searching, files, sessions,
  configuration.
- [Writing plugins](plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](agents.md): `kern ctl`, MCP, proposals, `/ide` and plugins
  written by agents.
- [How Kern is built](design.md): what lives in Rust, what lives in Luau,
  and why.

These pages are plain Markdown, readable in a terminal or in Kern itself,
and `mdbook build docs` turns them into a website.

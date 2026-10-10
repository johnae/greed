# Greed

Greed, a General Runtime for Editing, Extending and Delegating, is an
editor for the terminal and the environment around it, with a small Rust
core and everything else in Luau plugins you can read, change or replace
while it runs. You edit in the Vim, Helix or VS Code style, modal or
without modes, and switch with `:style`. Agents use the editor through MCP,
the shell and Claude Code's `/ide`, or run inside it, and propose edits you
review in the buffer.

New to Greed? Start it, answer its few questions, and run `:tutor`: it
teaches your style's keys with lines to practise on, then shows you around.

- [Using Greed](using.md): editing, searching, files, sessions,
  configuration.
- [Several clients](clients.md): terminals and windows on one session.
- [The shell](shell.md): commands as blocks you keep, search and run again.
- [Editing styles](editing-styles.md): the Vim, Helix and VS Code styles,
  their keys, and making your own.
- [Keys](keys.md): finding out what a key does, binding your own, panes
  and tabs.
- [Highlighting](highlighting.md): how code is highlighted and themed.
- [Writing plugins](plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](agents.md): `greed ctl`, MCP, proposals, `/ide`, agents inside
  Greed and plugins written by agents.
- [How Greed is built](design.md): what lives in Rust, what lives in Luau,
  and why.

These pages are plain Markdown, readable in a terminal or in Greed itself,
and they make the documentation at [greed.rs](https://greed.rs).

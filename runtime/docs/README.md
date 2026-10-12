# Greed

Greed (Get, Reflect, Eval, Edit, Delegate) is an execution environment
with a good editor built in, which you use in a terminal or a window, on
your machine or on the one where the work runs. It has a small Rust core
and everything else in Luau plugins you can read, change or replace while
it runs. You edit in the Vim, Helix or VS Code style, modal or without
modes, and switch with `:style`. Agents run inside it, Greed's own with
the model you choose or any ACP agent, or use it from outside through MCP
and the shell (and Claude Code's `/ide`), and propose edits you review in
the buffer.

New to Greed? Start it, answer its few questions, and run `:tutor`: it
teaches your style's keys with lines to practise on, then shows you around.

This manual comes with Greed too, as the version you run has it:
`space h d` goes to a page or heading (`:docs boards` straight to one),
and `space h /` searches it. Pages open as documents, their links
followed with `enter`; `esc` shows the Markdown.

- [Using Greed](using.md): editing, searching, files, sessions,
  configuration.
- [Several clients](clients.md): terminals and windows on one session.
- [The shell](shell.md): commands as blocks you keep, search and run again.
- [Boards](boards.md): live shell commands saved as a page of cards.
- [Charts](charts.md): any table as a chart that follows the numbers.
- [Editing styles](editing-styles.md): the Vim, Helix and VS Code styles,
  their keys, and making your own.
- [Keys](keys.md): finding out what a key does, binding your own, panes
  and tabs.
- [Highlighting](highlighting.md): how code is highlighted and themed.
- [Writing plugins](plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](agents.md): `greed ctl`, MCP, proposals, `/ide`, agents inside
  Greed and plugins written by agents.
- [Permissions and sandboxing](permissions.md): what agents and plugins
  may do, what asks you, and rules that answer for you.
- [How Greed is built](design.md): what lives in Rust, what lives in Luau,
  and why.

These pages are plain Markdown, readable in a terminal or in Greed itself,
and they make the documentation at [greed.rs](https://greed.rs).

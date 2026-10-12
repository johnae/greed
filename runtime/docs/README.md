# Greed

Greed is a modal text editor with Helix, Vim and VS Code keys, a shell,
terminals and agent support. It runs in a terminal or a window, locally or
over ssh. The core is a small Rust program; everything else is Luau
plugins you can read, change or replace while it runs.

- You edit in the Vim, Helix or VS Code style, and `:style` switches.
- Agents run inside it (Greed's own with the model you choose, or any ACP
  agent) or use it from outside through MCP, the shell and Claude Code's
  `/ide`. They propose edits you review in the buffer.

To start, run `greed`, answer its few questions, then `:tutor`: it teaches
your style's keys with lines to practise on, then shows you around.

This manual comes with Greed, matching the version you run:

| Keys | |
|---|---|
| `space h d` | Go to a page or heading (`:docs boards` goes straight to one) |
| `space h /` | Search the manual |

Pages open as documents: `enter` follows a link, `esc` shows the Markdown.

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

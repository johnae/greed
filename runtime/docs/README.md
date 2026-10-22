# Greed

Greed is a modal text editor. You pick the keys (Helix, Vim or VS Code), and it
comes with a shell, terminals, notes and mail, with agents in all of them. It runs
in a terminal or a window, locally or over ssh.

I wanted an editor I could bend as far as Emacs, without it ever freezing on me
while a plugin thinks. So the core is a small Rust program, and everything else -
the keys you edit with, modes, commands, pickers, themes, the agents - is Luau
plugins you can read, change or swap out while it runs.

To start, just run `greed`, answer its few questions, then `:tutor` - it walks you
through your style's keys with lines to practise on, then shows you around.

This manual comes with Greed, so it matches the version you run. In Greed:

| Keys | |
|---|---|
| `space h d` | Go to a page or heading (`:docs boards` goes straight to one) |
| `space h /` | Search the manual |

Pages open as documents: `enter` follows a link, `esc` shows the Markdown.

## What's in here

- [Using Greed](using.md): editing, searching, files, sessions and configuration.
  The place to start.
- [Hoard](hoard.md): your notes and todos, as plain Markdown files.
- [Several clients](clients.md): terminals and windows on one session.
- [Sessions, machines and the hub](sessions.md): what runs where, and one key to
  get there.
- [The shell](shell.md): commands as blocks you keep, search and run again.
- [Boards](boards.md): live shell commands saved as a page of cards.
- [Charts](charts.md): any table as a chart that follows the numbers.
- [Mail](mail.md): your IMAP accounts, searched as you type.
- [Editing styles](editing-styles.md): the Vim, Helix and VS Code styles, their
  keys, and making your own.
- [Keys](keys.md): finding out what a key does, and binding your own.
- [Highlighting](highlighting.md): how code is highlighted and themed.
- [Writing plugins](plugins.md) and [Building interfaces](ui.md): commands, keys,
  decorations, panels, tests and types, and drawing your own lists and fields.
- [Agents](agents.md): `greed ctl`, MCP, proposals, `/ide`, and agents inside Greed.
- [Permissions and sandboxing](permissions.md): what agents and plugins may do,
  and what asks you.
- [How Greed is built](design.md): what lives in Rust, what lives in Luau, and why.

It's really early days, so expect a few things here to change. If something's
wrong or missing, an issue or a pull request is very welcome.

These pages are plain Markdown, readable in a terminal or in Greed itself, and
they make the documentation at [greed.rs](https://greed.rs).

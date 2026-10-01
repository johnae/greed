# How Kern is built

Kern has a small core written in Rust and a large layer written in Luau.
Knowing where the line is tells you what you can change from a plugin
(almost everything) and where to look when something is slow.

## The rule

If it can be written in Luau, it is. The core holds what needs speed,
threads or the operating system, and offers it to Luau as small, general
functions. Everything you see and use is built from those functions, the
same way any plugin would build it.

In Luau:

- The editing model: modes, motions, selections, operators, the keymaps.
  Helix-style editing is the `core` plugin, edit mode is another, and a
  Vim mode is an example in `runtime/examples`.
- Commands, the command line, pickers, the file tree, search and replace,
  the status line, key hints, help.
- The theme and every animation.
- Language settings, which language server to start and how.
- The agent integration: the MCP tools, the review of proposed edits,
  Claude Code's `/ide` protocol, plugins written by agents.

In Rust:

- Text: the rope, selections, changes, undo history.
- Layout and rendering: turning buffers, decorations and the theme into
  frames a client draws.
- Parsing (tree-sitter), regex search, project-wide grep and diffs.
- Talking to the outside: language servers, the session socket, Claude
  Code's WebSocket, files.
- Running things off the editor thread, and waking the Luau code waiting
  for them.
- Loading, sandboxing and checking plugins.

When a feature needs something Luau can't do, the core grows by the
smallest primitive that unblocks it, and the feature itself stays in Luau.
Project search is an example: the core searches files on a background
thread, while the picker, the waiting for a pause in typing, the results
panel and writing edits back are Luau.

## Sessions and clients

The editor runs as a session: one process that owns the buffers, the Luau
plugins and the language servers. Clients connect to it. The terminal UI is
one client: it sends keys and draws the frames it gets back. `kern ctl`,
`kern mcp` and Claude Code are others, and a graphical client can be added
the same way.

Because the session owns the state, a terminal can detach and reattach
without losing anything, and `kern ssh` attaches a terminal on one machine
to a session on another. A client says which protocol it speaks when it
attaches, and the session refuses clients it can't talk to instead of
misreading them.

Frames describe what to show by meaning, like "selection", "keyword" or
"diagnostic.error", and carry the theme that maps those names to colors.
A terminal and a GUI can draw the same frame, and theme entries can style
each one differently. An attached client gets a whole frame once, and after
that only what changed: typing a character sends a row or two, and the
theme goes along only when it changes.

## Plugins are contained

Each plugin runs in its own environment with a read-only standard library.
A call that runs too long is stopped, so a buggy loop can't freeze the
editor. Everything a plugin registers (commands, keys, options, event
handlers, theme entries, tools) belongs to it, so reloading or unloading a
plugin cleanly replaces or removes all of it.

Plugins that wait (for a timer, a key, a language server, a search) are
paused and resumed by the editor. The code reads top to bottom with no
callbacks, and the editor keeps responding meanwhile.

## Agents are clients too

Agents see the same editor state you do, and their edits arrive as
proposals in the buffer that you accept or reject. When they extend Kern,
their plugins go through the same type checking and tests as any other, and
you review them before they load.

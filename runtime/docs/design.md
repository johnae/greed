# How Greed is built

Greed has a small core written in Rust and a large layer written in Luau.
Knowing where the line is tells you what you can change from a plugin
(almost everything) and where to look when something is slow.

## The rule

If it can be written in Luau, it is. The core holds what needs speed,
threads or the operating system, and offers it to Luau as small, general
functions. Everything you see and use is built from those functions, the
same way any plugin would build it.

In Luau:

- The editing model: modes, motions, selections, operators, the keymaps.
  The `core` plugin holds the editing commands; Helix, Vim and vscode
  are plugins that give them keys, each with modes of its own, and
  `:style` switches between them.
- Commands, the command line, pickers, the file tree, search and replace,
  the status line, key hints, help.
- The theme and every animation.
- Language settings, which language server to start and how.
- The agent integration: the MCP tools, the review of proposed edits,
  Claude Code's `/ide` protocol, plugins written by agents, and Greed's
  own agent with its chat.
- The shell: its prompt, blocks, tables, completion and watches.

In Rust:

- Text: the rope, selections, changes, undo history.
- Layout and rendering: turning buffers, decorations and the theme into
  frames a client draws.
- Parsing (tree-sitter), regex search, project-wide grep and diffs.
- Programs and terminals: running processes, the terminal emulator, and
  reading images and PDFs.
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
one client: it sends keys and draws the frames it gets back. The window
(`greed --gui`) is another that draws the same frames, and `greed ctl`,
`greed mcp` and Claude Code connect too.

Because the session owns the state, a terminal can detach and reattach
without losing anything, and `greed ssh` attaches a terminal on one machine
to a session on another. Any number of clients can be attached at once,
each with its own cursors, focus, mode and screen size; the server draws a
frame for each. A client says which protocol it speaks when it
attaches, and the session refuses clients it can't talk to instead of
misreading them.

The editor acts for one client at a time, and every command, key and event
handler knows which. Clients that follow share one layout of projects,
tabs and panes, each with its own focus and zoom; an independent client
has a layout of its own, a copy of the shared one with views of its own.
Floats are placed in shares of the screen, so they keep their proportions
on screens of other sizes, and the ones a client opens, like a picker, are
drawn for it alone. A view can be laid out at one size for every client,
as a terminal is for the client typing into it; the others crop or scale
it. [Several clients](clients.md) describes this from the user's side.

Frames describe what to show by meaning, like "selection", "keyword" or
"diagnostic.error", and carry the theme that maps those names to colors.
A terminal and a GUI can draw the same frame, and theme entries can style
each one differently. A frame is a stack of surfaces (panes, panels,
floats, the tab and status lines), each with its own rows and a role that
says how the client draws around it. An attached client gets a whole frame
once, and after that only what changed, surface by surface: typing a
character sends a row or two of one pane, focusing another pane sends two
roles, moving a float sends its new place, and the theme goes along only
when it changes.

## Plugins are contained

Each plugin runs in its own environment with a read-only standard library.
A call that runs too long is stopped, so a buggy loop can't freeze the
editor. Everything a plugin registers or starts (commands, keys, options,
event handlers, theme entries, tools, tasks, marks, floats and panels)
belongs to it, so reloading or unloading a plugin cleanly replaces or
removes all of it.

Plugins that wait (for a timer, a key, a language server, a search) are
paused and resumed by the editor. The code reads top to bottom with no
callbacks, and the editor keeps responding meanwhile.

## Agents are clients too

Agents see the same editor state you do, and their edits still go
through you: they arrive as proposals in the buffer that you accept or
reject, or, for Greed's own agent, ask first with the change shown as a
diff, unless you allowed that kind of change for the session. When they extend Greed,
their plugins go through the same type checking and tests as any other, and
you review them before they load.

## Performance budgets

How fast Greed is gets checked like everything else: `cargo test` runs a
set of budgets, each a measurement with a limit it must stay under.

- Starting with every default plugin, to the first frame, on an empty
  file and on a 10,000 line Rust file.
- Opening a file of a million lines, and one of 100 MB, then moving around
  and typing in them: the time per key, and the memory the file adds.
- 500 files open: opening them, moving, the buffer picker.
- A long session of opening, editing, undoing, splitting and closing, for
  the memory each round leaves behind, so a leak fails a test.
- Three clients attached, one typing beside a split, a terminal and a
  float: the time per key and the bytes each client gets for it, and what
  the session uses while nothing happens.
- Searching 2,000 files, and highlighting a 20,000 line file again after
  an edit.

Times are CPU time, which a busy machine changes far less than the clock,
and each measurement runs in a process of its own. The limits are a few
times what was measured, so a loaded machine or a debug build doesn't fail
them while something becoming several times slower does.

To see each measurement next to its limit:

```sh
GREED_BUDGETS=report cargo test --release -p greed-core --test budgets -- --nocapture
```

Adding `--include-ignored` also runs a session of several minutes. For how
keys feel in your own setup, with your plugins and config, `greed bench`
times each key from the terminal client's side.

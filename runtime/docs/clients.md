# Several clients on one session

Any number of terminals and windows can show one session at once: run
`greed` or `greed attach` in a second terminal, `greed --gui` for a window,
or `greed ssh HOST` from another machine. Each is a client of the session.
They edit the same buffers, with one undo history per buffer, and each has
its own cursors.

```sh
greed notes.md            # in one terminal: starts the session
greed attach              # in another: shows the same session
greed ssh desk notes.md   # from a laptop: the session on desk
```

## What each client has

Each client keeps these to itself:

- its cursors and selections, and where each view is scrolled;
- the view it has focused, and its mode and half-typed keys;
- pane zoom (`:pane-zoom`), even while it follows the others;
- pickers, prompts, the command line, completion and hover: they show only
  on the client that opened them, and only its keys reach them;
- `.`, which repeats that client's own last change, and macro recording;
- the font size of a window: `ctrl-=` and `ctrl--` zoom the window you type
  them in, `ctrl-0` puts it back, and setting `gui-font-size` sets it for
  every window again;
- copies, which go to the system clipboard of the client that copied.

Buffers, their undo history, the clipboard history, projects and options
are shared. Desktop notifications go to the client you used last.

## Following, or laid out on its own

A client that attaches follows the others: it shows the same project, the
same tab and the same panes, with its own focus and zoom. When one opens a
tab, switches project or splits a pane, the others show that too.

Another client never moves you while what you're in still shows: you can
go on typing in a file or a terminal while someone splits a pane or opens
a panel. When what you had focused goes out of sight (another tab or
project is shown, or the pane closes), you move to the shown tab's active
pane, what you had typed halfway is dropped, and you're back in normal
mode there, so keys meant for a terminal never land in a file.

| Command | |
|---|---|
| `:client-independent` | Give this client a layout of its own. It starts from a copy of what it showed (the same tabs, panes, panels and the tab's floating terminals, as new views of the same buffers, scrolled and selected the same); from then on its tabs, panes and project change apart from the others' |
| `:client-follow` | Follow the others again. The panes it had on its own close, their buffers stay open, and you go on in the file you were in, in the pane the others show it in |

Both say what they did at the bottom.

Floats keep their place and size in proportion on screens of different
sizes: a float in the middle of a big window is in the middle of a small
terminal too. A tab's floats, like floating terminals, are shown to every
client showing that tab.

## Seeing each other

Each client's cursors and selections show for the others in a color of
its own, one of six: client color N uses `ui.cursor.peer.N` and
`ui.selection.peer.N`, which fall back to `ui.cursor` and `ui.selection`.
The built-in themes give each a color of their palette. A client laid out
on its own shows its cursors where it works, in a view of the same buffer.

## Terminals

A program in a terminal pane has one screen size. It's the size of the
client that last typed into the terminal, pasted into it or focused it,
and a terminal window resizing changes it only for that client, so two
clients never fight over it. The others see the program's screen as it is:
a terminal crops it to the rows around the program's cursor (or its bottom
rows), and where it's smaller than the pane, shows a note like
`80×24 for tui@laptop` in the room left over; a window scales it to fit.
Typing into it from another client sizes it for that one.

Image files and PDFs fit the width of the client that opened them or last
focused them, in the same way.

## Leaving and coming back

`:detach` (or closing the terminal) lets one client go and leaves the
others attached. A client is known by its kind and machine, like
`tui@laptop` or `gui@desk`, with a number when there are two of a kind on
one machine (`tui@laptop#2`). One coming back by the same name gets its
cursors, focus, mode and layout back: it takes the first name no attached
client has, so the second terminal on a laptop to come back gets what
`tui@laptop#2` had. A new one follows the others and starts where the
last-used client is.

`:quit-session` ends the session for every client, whatever runs in it,
unless files have unsaved changes (`:quit-session!` ends it anyway).
From a shell, `greed ctl quit NAME` ends it unless files have unsaved
changes (`--force` ends it anyway); it works on a session of another
Greed version too, as after an upgrade.

## For plugins

Code always acts for one client: the one whose key, click or menu ran a
command, or the one an event is about.

| API | |
|---|---|
| `ctx.client`, `greed.client.id()` | Which client is acting |
| `greed.client.current()` | Its name, kind, size and layout |
| `greed.client.list()` | Every attached client |
| `greed.client.set_layout("independent" \| "follow", id?)` | What the two commands above use |
| `greed.client.set_status_line(shown, id?)` | Hides or shows one client's status line, as slides do while you present |
| `greed.option.set(name, value, { client = true })` | A value of its own for the acting client |
| `buffer:set_screen_size` | Lays a buffer out at one size in every view, as terminals do |

State a plugin keeps for what a client has open, like a picker, belongs in
a table keyed by `greed.client.id()`. A float is shown only to the client
it opened for unless its spec says `shared = true`; sizes and places like
`"37.5%"` keep it in proportion on every client. [Writing plugins](plugins.md)
has more.

A client that attaches over the session socket can ask to be laid out on
its own with `"layout": "independent"` in its attach request.

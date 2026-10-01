# Using Kern

## Starting and sessions

`kern FILE` opens a file. The editor runs as a session in the background and
your terminal attaches to it, so closing the terminal (or typing `:detach`)
leaves everything as it was: open files, undo history, language servers.

Each project gets its own session, named after its folder. Running `kern`
anywhere in a project attaches to that project's session if it's running
(opening the file you named), or starts it. Projects in separate sessions
don't affect each other: a slow plugin or a crash in one leaves the others
alone.

| Command | What it does |
|---|---|
| `kern [FILE or FOLDER]` | Attach to the project's session, or start it |
| `kern --session NAME [PATH]` | Attach to or start a session with this name, e.g. a second one for a project |
| `:detach` | Leave the session running |
| `kern attach [NAME]` | Attach to a session; the only one if there's one |
| `kern ls` | List running sessions and their projects |
| `kern serve [PATH]` | Run a project's session with no terminal |
| `:q` | Close the shown project and leave; on the last one, quit the session |

Switching to another session (`space P`, `:session`) moves your terminal
there and leaves the session you were in running. Over `kern ssh` it
reconnects through a new ssh connection, which is close to instant with
ssh connection sharing (`ControlMaster`).

Attaching from a second terminal takes the session over from the first. If
a session can't start in the background, `KERN_NO_SESSION=1 kern FILE` runs
the editor directly in the terminal.

## Projects

A project is a folder you work in: the nearest folder above a file that
holds `.jj` or `.git`, or the folder itself if none does. A session can also
hold several projects, for ones you work on together: each has its own
files, main view and panels (the file tree, search results), and the file
picker, project search and tree work within the shown one.

| Keys | |
|---|---|
| `:project PATH` | Open the project `PATH` is in, or switch to it |
| `space P` | Switch to another project: one open in this session, or another running session |
| `:session NAME` or `:session PATH` | Go to a running session, or to the session for a project (starting it) |
| `:project-close` | Close the shown project |
| `:q` | Close the shown project and leave; on the last one, quit |
| `:qa` | Quit every project |

## Editing on another machine

```bash
kern ssh build-box src/main.rs
```

`kern ssh HOST [--session NAME] [FILE]` shows a session running on another
machine, starting one there if none is running. Files, language servers,
search and agents all run on that machine, and only keys and screen updates
cross the network. If the connection drops or you `:detach`, the session
keeps running, and `kern ssh HOST` comes back to it.

Your config comes along: `kern ssh` copies `~/.config/kern` (your
`init.luau` and plugins) to the other machine first, and a session it
starts there uses that copy, so the editor works the way you set it up.
A session that was already running keeps the config it started with.
`KERN_SSH_CONFIG=0` leaves your config at home. Plugins an agent installs
while you're in a remote session go into that copy, which the next
`kern ssh` replaces, so keep the ones you want in your own config.

Kern has to be installed on both machines. The two ends check that they
speak the same protocol and say so if they don't, so mismatched versions
fail with a clear message. `KERN_REMOTE` sets the path of `kern` on the
other machine, and `KERN_SSH` the ssh command to use.

## Editing

Kern edits the way Helix does: you select text, then say what to do with it.
There is always a selection; a cursor is a selection one character wide.

**Moving and selecting** (normal mode)

| Keys | |
|---|---|
| `h j k l`, arrows | Move |
| `w` `b` `e` | Select to the next word, previous word, word end |
| `x` | Select the line |
| `g g` `g e` | Start and end of the file |
| `g h` `g l` | Start and end of the line |
| `g w` | Label every word on screen; type a label to jump there |
| `;` `alt-;` | Collapse the selection to the cursor, swap its ends |
| `%` | Select the whole file |

**Changing**

| Keys | |
|---|---|
| `i` `a` | Insert before or after the selection |
| `o` `O` | Open a line below or above |
| `d` `c` | Delete, or delete and insert |
| `y` `p` `P` | Copy, paste after, paste before |
| `u` `U` | Undo, redo |
| `esc` | Back to normal mode |

**Many selections**

| Keys | |
|---|---|
| `s` | Select every regex match inside the selections |
| `S` | Split the selections at a regex |
| `alt-s` | Split the selections into lines |
| `K` `alt-K` | Keep or drop the selections that match a regex |
| `C` `alt-C` | Add a selection on the line below or above |
| `,` `alt-,` | Keep only the primary selection, or drop it |
| `(` `)` | Make the previous or next selection primary |

With several selections, everything you type or delete happens at each one.
`%`, then `s foo`, then `c bar` replaces every `foo` in the file.

If you'd rather edit like Vim, or without modes, `:style vim` and `:style
edit` switch to those; [Editing styles](editing-styles.md) explains each.

**Prose**: `m i p`, `m i s` and `m i h` select a paragraph, sentence or
Markdown section (`m a ...` includes the space around it), and `] p` `[ p`,
`] s` `[ s` move between them.

## Searching

| Keys | |
|---|---|
| `/` `?` | Search forward or back as you type |
| `n` `N` | Next and previous match |
| `*` | Search for the selected text, exactly as written |
| `space /` | Search the whole project as you type |

Patterns are regexes; ones written in lowercase ignore case.

In the project search, `enter` opens a match and `ctrl-e` puts what was
found in a panel. You can edit the lines in that panel with any of the
editing keys above, and `:w` writes the changes back to their files. Lines
that changed since the search are left alone and reported. `:grep PATTERN`
fills the panel directly.

## Files and buffers

| Keys | |
|---|---|
| `space f` | Find a file in the project |
| `space b` | Switch to an open file |
| `space e` | File tree in a side panel |
| `:w` `:w PATH` | Save, or save as |
| `:e PATH` | Open a file |
| `ctrl-s` | Save |

## Language servers

Kern knows the usual languages and their servers and starts a server when a
file needs one and it's installed. `:health` shows each language's server
and whether it was found.

| Keys | |
|---|---|
| `space k` | What's under the cursor, with any problems there |
| `g d` | Go to the definition |
| `space d` | Pick a problem in this file |
| `] d` `[ d` | Next and previous problem |

## The command line

`:` (or `alt-x` in edit mode) runs any command by name, with completion.
`space ?` lists every command, `space h c` describes one and `space h k`
tells you what a key does. After a key like `space`, a hint shows what can
follow.

## Configuration

Your config is `~/.config/kern/init.luau`, plain Luau with the full plugin
API. Your own plugins go in `~/.config/kern/plugins/NAME/`.

```luau
local kern = require("@kern")

-- Keys
kern.keymap.bind("normal", { ["space w"] = "save" })

-- Options (`:set` changes them while running)
kern.option.set("flash-duration", 150)

-- The theme: change a few names, or all of them
kern.theme.set({
	["ui.selection"] = { bg = "#3b3f51" },
	["keyword"] = { fg = "magenta", bold = true },
})

-- A language
require("@languages").set("python", { servers = { { "pylsp" } } })

-- Turn off a default plugin
kern.plugin.unload("hints")
```

Theme names fall back to their parent, so `keyword.control` uses `keyword`
unless it has its own entry. The default theme uses the terminal's 16
colors; `#rrggbb` colors work in terminals that support them.

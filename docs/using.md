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
| `space P` | Switch project: one open here, another running session, or a recent one; type a folder path to open it |
| `:session NAME` or `:session PATH` | Go to a running session, or to the session for a project (starting it) |
| `:project-close` | Close the shown project |
| `:q` | Close the shown project and leave; on the last one, quit |
| `:qa` | Quit every project |

A recent project or a folder typed into `space P` opens in its own session,
starting it if it isn't running, like `kern FOLDER` from a terminal.
`:project PATH` opens a project in this session instead. `space P` works the
same in the Helix and Vim styles; in edit mode, where space types, pick
`pick-project` from the command palette (`ctrl-P`).

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
starts there runs that copy, so the editor works the way you set it up.
The other machine's own `~/.config/kern` runs after it and wins, and
`kern ssh` never touches it. Changes you make there, or an agent makes, or
plugins an agent installs, stay on that machine across connections. A
session that was already running keeps the config it started with.
`KERN_SSH_CONFIG=0` leaves your config at home.

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
| `W` `B` `E` | The same for WORDs, which include punctuation (`a.b`) |
| `f` `t` + a character | Select to the next one on the line, or up to it; `F` `T` go back |
| `x` | Select the line |
| `g g` `g e` | Start and end of the file |
| `G`, `5 G` | The last line, or line 5 |
| `g h` `g l` `g s` | Start and end of the line, first character that isn't a space |
| `m m` | The matching bracket |
| `g w` | Label every word on screen; type a label to jump there |
| `;` `alt-;` | Collapse the selection to the cursor, swap its ends |
| `%` | Select the whole file |
| `ctrl-f` `ctrl-b` | A screen down or up (also `pagedown` `pageup`) |
| `ctrl-d` `ctrl-u` | Half a screen down or up |
| `z z` | Put the cursor's line in the middle of the screen |
| `ctrl-o` `ctrl-i` | Back to where the last jump (a search, `g g`, `g d`, a file you opened) started, and forward again |

**Changing**

| Keys | |
|---|---|
| `i` `a` | Insert before or after the selection |
| `o` `O` | Open a line below or above |
| `I` `A` | Insert at the start or end of the line |
| `d` `c` | Delete, or delete and insert, copying what was deleted |
| `alt-d` `alt-c` | The same without copying |
| `r` + a character | Replace every selected character with it |
| `R` | Replace the selections with what was copied |
| `~` `` ` `` `` alt-` `` | Switch case, lowercase, uppercase |
| `>` `<` | Indent or dedent the lines (the `indent` option sets by what) |
| `J` | Join lines with one space |
| `ctrl-c` | Comment the lines, or uncomment them |
| `y` `p` `P` | Copy, paste after, paste before |
| `"` + a letter | Use that register for the next copy, paste, delete or macro, instead of the clipboard |
| `Q` `q` | Start or stop recording a macro, play it (`3 q` three times) |
| `u` `U` | Undo, redo |
| `esc` | Back to normal mode |

A number before a motion repeats it: `3 j`, `2 w`.

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
| `v` | Select mode: moves extend the selection, `n` `N` add the next match as another selection |

With several selections, everything you type or delete happens at each one.
`%`, then `s foo`, then `c bar` replaces every `foo` in the file. `s` with
nothing typed uses the last search, so `*` on a word, then `% s enter`,
selects every place it appears.

**Text objects and surround**

| Keys | |
|---|---|
| `m i w` `m a w` | The word, or the word and the space after it (`W` for WORDs) |
| `m i (` `m a (` | Inside or around the brackets; also `[` `{` `<` |
| `m i "` `m a "` | Inside or around the quotes; also `'` and `` ` `` |
| `m s (` | Wrap each selection in brackets, quotes, or any character |
| `m d (` | Take away the brackets or quotes around each selection |
| `m r ( [` | Swap them for others |

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

Completions show as you type, in a menu at the cursor, once typing pauses
after a letter or a `.`. The menu narrows as you keep typing.

| Keys | |
|---|---|
| `tab` `ctrl-n` `down` | Next completion |
| `shift-tab` `ctrl-p` `up` | Previous completion |
| `enter` | Put the current one in |
| `esc` | Close the menu (and leave insert mode) |
| `ctrl-space` | Ask for completions now |

`:set completion-delay 300` waits longer before asking; `0` stops asking
while you type, leaving `ctrl-space`.

## Version control

In a jj or git repository, lines added (`+`), changed (`~`) and removed
(`-`) since the last commit get a sign beside them. With jj that's against
the working copy's parent, so the signs show what your current change does.

| Keys | |
|---|---|
| `] g` `[ g` | Next and previous change |
| `space g r` | Put the change under the cursor back the way it was |
| `space g b` | Who last changed this line, and when |

`:set vcs-signs false` hides the signs.

## Formatting

Saving a file formats it, and `:format` does it without saving. Kern uses
the language's formatter when it's installed (`gofmt`, `ruff`, `stylua`,
`prettier`, `shfmt`, ...) and otherwise asks the language server, which is
how Rust gets `rustfmt` through rust-analyzer. Only what the formatter
changed is replaced, so your cursor stays put.

```luau
-- A different formatter for a language
require("@languages").set("python", { formatter = { "black", "-q", "-" } })

-- No formatting on save
require("@kern").option.set("format-on-save", false)
```

A formatter gets the text on its input and prints it formatted; `{path}` in
its command stands for the file's path.

## Notes

Notes are Markdown files in a folder (`~/notes` unless you set
`notes-folder`), so git or Syncthing can carry them between machines and to
your phone. Link one to another with `[[name]]`, or `[[name|other words]]`
to show other words.

| Keys | |
|---|---|
| `space n d` | Today's note, in `daily/` |
| `space n c` | Add a todo to `inbox.md`, from wherever you are |
| `space n a` | The agenda: open todos from every note, soonest due first |
| `space n f` | Find a note; a name that isn't one yet makes it |
| `space n /` | Search every note as you type |
| `space n x` | Tick a todo or untick it; a plain line becomes one |
| `g d` | Follow the link under the cursor, making the note if it's new |
| `z a` | Fold the section under the cursor, or unfold it (any Markdown) |

A todo is a list item with a box, `- [ ] call the bank`, and
`due:2026-10-03` anywhere in it gives it a date for the agenda. In a note,
links show without their brackets (except on the cursor's line) and the
notes linking to it are listed at its end. Other Markdown files, like a
project's README, look as they always do; `:set notes-everywhere true`
treats every Markdown file as a note, and `:set notes-conceal false` shows
the brackets.

```luau
require("@kern").option.set("notes-folder", "~/Documents/notes")
```

Agents can read and write your notes and todos too; see
[Agents](agents.md).

## The command line

`:` (or `alt-x` in edit mode) runs any command by name, with completion.
`space ?` lists every command, `space h c` describes one and `space h k`
tells you what a key does. After a key like `space`, a hint shows what can
follow.

## Configuration

Your config is `~/.config/kern/init.luau`, plain Luau with the full plugin
API. Your own plugins go in `~/.config/kern/plugins/NAME/`.

Config runs in layers, each after the one before, so later ones win:

1. The default plugins.
2. The config `kern ssh` brought from your machine, in a session on
   another one.
3. This machine's own config, `~/.config/kern`.
4. The project's own config, `.kern/init.luau` in the project, once you
   trust it.

A project's config is code from whoever wrote the repository, so it doesn't
run until you say so: opening a project that has one tells you, and
`:trust` runs it, now and whenever the project opens again. Trusted
projects are listed in `~/.cache/kern/trusted-projects`; take a line out
to stop trusting one.

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

[Keys](keys.md) covers key names, modes and taking keys away.

Theme names fall back to their parent, so `keyword.control` uses `keyword`
unless it has its own entry. The default theme uses the terminal's 16
colors; `#rrggbb` colors work in terminals that support them.

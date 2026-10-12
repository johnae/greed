# Using Greed

## Starting and sessions

`greed FILE` opens a file. The editor runs as a session in the background and
your terminal attaches to it, so closing the terminal (or typing `:detach`)
leaves everything as it was: open files, undo history, language servers.

Each project gets its own session, named after its folder. Running `greed`
anywhere in a project attaches to that project's session if it's running
(opening the file you named), or starts it. Projects in separate sessions
don't affect each other: a slow plugin or a crash in one leaves the others
alone.

| Command | What it does |
|---|---|
| `greed [FILE or FOLDER]` | Attach to the project's session, or start it |
| `greed --session NAME [PATH]` | Attach to or start a session with this name, e.g. a second one for a project |
| `greed --new [PATH]` | Start another session for the project, beside the one running, with this greed: for trying a newer build |
| `:detach` | Leave the session running |
| `greed attach [NAME]` | Attach to a session; the only one if there's one |
| `greed ls` | List running sessions and their projects, marking those running another build than this greed |
| `greed serve [PATH]` | Run a project's session with no terminal |
| `:q` | Close the pane, as Vim closes a window, when the tab has others; the tab, when it's the last pane and there are other tabs. Otherwise close the shown project and leave; on the last one, end the session unless something is running in it (see below). In a panel or a float (an agent's transcript, help) it closes just that |
| `:quit-session`, `:qa` | End the session, whatever runs in it. With unsaved files it lists them and stops; `:wa` saves them, `:wqa` saves them and ends it, `:qa!` ends it anyway |
| `greed edit [--wait] FILE...` | Open files in the running editor; with `--wait`, return once each is closed with `:q` or `:wq` (`:cq` fails it), as `$EDITOR` for `git commit`. Greed's own shells set this up already |
| `greed ctl quit [--force] [NAME]` | End a session from a shell, unless it has unsaved changes (`--force` ends it anyway) |

A session keeps running the greed it started with. `greed --version` says
which build a greed is (`greed 0.1.4 (build b5432b407145)`, a hash of what it
was built from), and attaching to a session of another build, as after
rebuilding greed while it ran, says so on the status line: `greed --new`
starts a session of your build beside it, and `greed ctl quit NAME` ends the
old one. `greed ssh` puts your build on the other machine when it runs the
same system, so a rebuild gets there too; the last few builds are kept there.

A session of another version of Greed, as after upgrading while it ran,
can't be shown at all: the two don't speak the same protocol. Greed then
shows a page saying so, with the files that have unsaved changes there and
what's running, and asks what to do, in the terminal or the window, and
over `greed ssh` too: end it and start your version in its place, open it
with the version it runs to save your work first (when that greed is still
on this machine), or start your version beside it. A number picks, `esc`
leaves it as it is. `greed ctl state NAME` prints what's unsaved and running
in a session of any version, and `greed ctl quit NAME` ends one from a shell
(both work across versions); the next `greed` then starts a new one.

Several terminals can show one session at once: run `greed` or `greed
attach` in another terminal, or `greed ssh` from another machine, and both
stay attached. They share the buffers and their undo history; each has its
own cursors, focus and mode, and `:detach` lets only that one go. A terminal
that comes back from the same machine gets its cursors, focus and mode back;
a new one starts where the one used last is. Copies go to the clipboard of
the terminal that copied, and desktop notifications to the one used last.

Attached terminals follow each other: they show the same project, tab and
panes, each with its own focus and pane zoom. `:client-independent` lays one
out on its own, and `:client-follow` has it follow again. Pickers, prompts
and the command line show only on the terminal that opened them, and a
program in a terminal pane is sized for the client that last typed into it.
[Several clients](clients.md) has the details.

`greed commands` lists every command line command, including the ones
plugins add (`greed ls`, `greed new` and `greed bring` are plugins too).

Switching to another session (`space P`, `:session`) moves your terminal
there and leaves the session you were in running. Over `greed ssh` it
reconnects through a new ssh connection, which is close to instant with
ssh connection sharing (`ControlMaster`).

In one of Greed's own terminals, `greed FILE` opens the file in that session
and returns, rather than starting an editor inside the editor, and
`greed ctl` talks to that session. Programs there can tell from
`$GREED_TERMINAL`, which names the session.

If a session can't start in the background, `GREED_NO_SESSION=1 greed FILE`
runs the editor directly in the terminal.

A session that quits remembers its projects, their open files and where the
cursor was, and the tabs of the project you were in: their panes, what
each showed, and the terminals in them, which run what they ran again (a
terminal that ran something risky, like `rm -rf` or `kubectl delete`,
comes back as a plain shell). It opens them again the next time it
starts. It writes this down when it quits and whenever you save a file, in
the cache folder (`~/.cache/greed/sessions`). Starting with a file keeps that file shown. To
start one session fresh, without them, use `greed --fresh` (or `greed ssh
HOST --fresh`); it only matters when a session starts, so quit a running
one first or start another with `--new`. On a Mac, holding Shift while
Greed opens does the same. Turn restoring off for good with
`greed.option.set("restore-session", false)`.

### Quitting or keeping a session

`:q` and `:wq` in a pane with others beside it close just that pane, as
they close a window in Vim, and in a tab's last pane they close the tab
while there are others. The file stays open, so this never asks about
unsaved changes. `ctrl-q` in the vscode style asks whether to save
unsaved files, quit without saving or cancel, as VS Code does.

`:q` on the last project ends the session, unless ending it would stop
something: a command running in one of its terminals, a program like a
task, or an agent at work. Then it detaches instead and the session keeps
going, so `greed` comes back to it. A shell waiting at its prompt doesn't
count. Over `greed ssh`, `:q` keeps the session by default, since coming back
to a running one is quicker than starting again over the network.
`:quit-session` (or `:qa`) ends it whatever runs in it. Files with unsaved
changes stop it: it lists them, `:wa` saves them and `:qa!` ends the
session anyway. Terminals, shells, agents' panes and other scratch buffers
never count as unsaved.

To decide for yourself, set what `:q` does, here and over `greed ssh`:

```luau
local greed = require("@greed")

-- "auto": end it unless something runs; "end": always end it;
-- "keep": always leave it running
greed.option.set("on-quit", "auto")
greed.option.set("on-quit-remote", "keep")
```

A session with nothing attached, nothing running and nothing unsaved ends
by itself after a day, so sessions don't pile up on machines you visit;
`session-idle-hours` changes how long, and 0 keeps them for good. Plugins
can say what of theirs is running with `require("@core").file.running`.

### The first time

Started without a config (`~/.config/greed/init.luau`), Greed shows a page
with a few questions: how you like to edit, which theme, whether your font
has icons (in a terminal, which needs a Nerd Font for them; the window has
them built in and doesn't ask), whether to add Greed's tools to Claude Code,
and which language model to use (Anthropic, OpenAI, Berget, Mistral, Ollama on this machine, or none
for now). A style or theme you pick switches at once, so you can try it on
the page.

The page is a [questionnaire](#questionnaires) in Markdown, and works the
same in every editing style: `tab` and `shift-tab` go from
choice to choice, `enter` or `space` picks one or presses a button, and a
click does too. Under the models, a button sets the API key (it goes in the
system keyring) or signs you in; for Ollama the page says whether it
answers, and if not, to run `ollama serve` and `ollama pull llama3.2`.

**Save** writes an `init.luau` from your answers and opens it, and has the
`fast` and `reasoning` roles use the provider you picked (`:models` changes
them later). Under your answers it lists settings worth trying, commented
out: remove the `--` in front of one and save, and it applies at once. It
also says how to find the rest: `space h o` describes an option, and
`:set NAME VALUE` tries one for the session. **Not now**, `esc`, `q` or
closing the page any other way closes it without writing anything. Either
way it doesn't show again by itself, and `:setup` brings it back, or goes
to it if it's open. Save never replaces a config that's there; it shows
what to add instead, and `esc` closes that.

`:tutor` teaches the keys of the style you picked, with a few lines to
practise on in each lesson, which say done once you've got them right, and
then shows you around Greed: the leader, finding files, panes, the shell
and sessions. Picking another style on the page switches to it, and the
lessons change with it. Nothing on the page is saved; `:tutor` gives you a
fresh one.

### In a window

`greed --gui [FILE]` shows the session in a window instead of the terminal,
drawn on the GPU. It's the same session either way: attach from a terminal
later and you see the same files, and `greed ssh HOST --gui` shows a session
on another machine in a window here. Closing the window lets the session
go, as `:detach` does.

The window draws with your system's monospaced font, ligatures included
when the font has them (Fira Code, JetBrains Mono, Cascadia Code), and
draws box lines itself so borders join cleanly. Images show as they do in
a terminal with kitty graphics, PDFs included. Dead keys and input methods
type as they do elsewhere, and the window opens at the size it last had. On
Linux it needs Wayland or X11 and a Vulkan or GL driver.

On macOS the menu bar holds Greed's menus (File, Edit, View, Pane, Help),
each item a command, after the Greed menu with Hide and Quit Greed (⌘Q).
Elsewhere there's no menu bar, and the command palette (`space ?`, or
`ctrl-P` in the vscode style) lists every command. Plugins and your
config add items:
`require("@core").menus.add("Tools", "Run tests", "test-run")`.

Dropping a file on the window pastes its path where you are, as a terminal
does, so dropping a screenshot on a terminal pane running Claude Code
hands it the picture. With the session on another machine (`greed ssh`),
the file is copied there first, into the cache folder's `dropped`, and that
path is pasted; files over 50 MB stay behind with a message saying so.
In a terminal, dropping a file pastes its path the same way; over `greed
ssh` a paste of nothing but paths to files on your machine sends the files
along too, so the session gets paths it can read.

What you copy in Greed goes on the system clipboard, and what you copied in
another program becomes Greed's clipboard when the window gets focus, so
`p` (or `ctrl-v` in the vscode style) pastes it. `ctrl-shift-v` and
`shift-insert` (`cmd-v` on macOS) paste the system clipboard at the cursors
in any mode, as a terminal's paste does.

Whole lines stay whole lines from one editing style to another: lines
copied with `y y` in the Vim style, `x y` in Helix's or `ctrl-c` with
nothing selected in the vscode style paste above or below the line in all
three.
Text copied in another program pastes where the cursor is.

`ctrl-=` and `ctrl--` make the text bigger and smaller, and `ctrl-0` puts
it back to the size it had before; with several windows on one session,
each zooms on its own. Pick another font and size in your `init.luau`; the
windows follow as soon as they change:

```luau
local greed = require("@greed")
greed.option.set("gui-font", "JetBrains Mono")
greed.option.set("gui-font-size", 14) -- pixels, before the screen's scale
greed.option.set("gui-font-prose", "Inter") -- prose, like Markdown's text
```

Prose (Markdown's text, and any style with `font = "prose"`) is set in a
proportional font, the system's sans-serif unless `gui-font-prose` names
one, at its own width; code stays in the grid's font. The cursor,
selections and clicks follow the text where it's drawn.

Floats (pickers, prompts, hover info) show as boxes with rounded corners
and a soft shadow, as the theme says for the window; terminals draw box
lines. Floats cast a shadow unless the theme turns it off, a lighter one on
a light background. The window draws the round ends of the status line's pills itself,
so they need no Powerline font. For square floats without shadows:

```luau
greed.theme.set({ ["ui.float"] = { gui = { rounded = false, shadow = false } } })
```

## Projects

A project is a folder you work in: the nearest folder above a file that
holds `.jj` or `.git`, or the folder itself if none does. A session can also
hold several projects, for ones you work on together: each has its own
files, main view and panels (the file tree, search results), and the file
picker, project search and tree work within the shown one.

| Keys | |
|---|---|
| `:project PATH` | Open the project `PATH` is in, or switch to it |
| `space P` | Go to a project: one open here, another running session, a recent one, or one your sources find; type a folder path (`~/src/`) to list the folders in it, `tab` to go into one |
| `alt-enter` in `space P` | Open the project in a new session, even if one is running for it |
| `space C` or `:connect HOST` | Show a session on another machine here, as `greed ssh` does: pick from the hosts you connected to lately and those in `~/.ssh/config`, or type one |
| `:session NAME` or `:session PATH` | Go to a running session, or to the session for a project (starting it) |
| `:project-close` | Close the shown project |
| `:q` | In the last pane of the last tab, close the shown project and leave; on the last project, end the session unless something runs in it |
| `:qa` | End the session and every project in it |

A recent project or a folder typed into `space P` opens in its own session,
starting it if it isn't running, like `greed FOLDER` from a terminal.
`:project PATH` opens a project in this session instead. Like every
`space` key here, it's the leader's: in the vscode style, where space types, it's
`ctrl-space P`.

To find projects you haven't opened yet, give `space P` sources in your
`init.luau`: folders to look in, and commands that print one path per line.

```luau
require("@projects").sources({
	-- every folder one level under these
	{ dirs = { "~/Development", "~/Work" } },
	-- deeper, but only folders that look like projects
	{ dirs = { "~/src" }, depth = 3, markers = { ".jj", ".git" } },
	-- any command that prints paths
	{ command = { "zoxide", "query", "-l" } },
	{ name = "ghq", command = { "ghq", "list", "-p" } },
})
```

The picker shows what they found the last time it looked, so it opens at
once, and looks again in the background each time it opens and when the
editor starts. Each entry says where it came from.

## Editing on another machine

```bash
greed ssh build-box src/main.rs
```

`greed ssh HOST [--session NAME | --new] [FILE]` shows a session running on
another machine, starting one there if none is running; `--new` starts
another one beside it. Files, language servers,
search and agents all run on that machine, and only keys and screen updates
cross the network. If the connection drops or you `:detach`, the session
keeps running, and `greed ssh HOST` comes back to it.

From inside Greed, `space C` (`:connect`, or Connect to Host… in the
window's File menu) does the same without a terminal: it lists the hosts
you connected to lately and those in `~/.ssh/config`, and the window or
terminal you're in moves to that machine's session. That way Greed.app on
a Mac, or a window on a Linux laptop, can be the screen for a workstation
where the work runs.

`greed ssh HOST --terminal` shows the session and opens a terminal on that
machine in a new tab, for when a shell is what you're after. It runs in the
session, so it's still there after you disconnect. `greed --terminal` does
the same here.
`greed --shell` (or `greed ssh HOST --shell`) shows the project's greed
shell instead, opening one if there's none (see [The shell](shell.md)).

### What runs where

The session runs on the other machine, and so does everything in it:
your config and plugins (all the Luau), files and saving, shells and
terminals, language servers, search and agents, with that machine's
programs, folders and variables. The Greed in front of you only draws the
screen and sends your keys, mouse and clipboard, so it needs nothing of
the project.

### Your config, both ways

Each `greed ssh` copies your `~/.config/greed` (`init.luau` and your
plugins) to the other machine first, into
`~/.cache/greed/config-from-<this machine>`, replacing the copy from last
time, and a session it starts runs that copy. So the editor there works
the way you set it up here.

- **Changed your config here?** Connect again and it's copied over. A
  session that was already running keeps the config it loaded; run
  `:config-reload` in it to run the fresh copy.
- **Something different on that machine?** Its own `~/.config/greed` runs
  after the copy and wins, and `greed ssh` never touches it. Put what's
  for that machine alone there: a setting in its `init.luau`, or a plugin
  with the same name as one of yours, which replaces yours there.

  ```luau
  -- ~/.config/greed/init.luau on build-box: only there.
  local greed = require("@greed")
  greed.option.set("line-numbers", "relative")
  ```

- **Changed something over there?** It stays there, across connections:
  edits to that machine's own config, and plugins you or an agent made or
  installed there. Nothing is copied back by itself. A plugin comes home
  with `greed bring` (below); a setting you want everywhere, copy into
  your own `init.luau` here.

`GREED_SSH_CONFIG=0` leaves your config at home.

To keep a plugin you made over there, bring it home. `greed bring HOST`
lists the plugins in the other machine's own config and data folders, and
`greed bring HOST PLUGIN` copies one into your config's `plugins` folder.
A running Greed loads it at once, asking you first to approve what it
uses.

```sh
$ greed bring build-box
build-box has these; greed bring build-box PLUGIN copies one here:
  /home/me/.config/greed/plugins/todo-sync
$ greed bring build-box todo-sync
```

### What the other machine needs

Your login shell on the other machine can be anything (bash, fish,
nushell): `greed ssh` only asks it to start `sh`, and needs a POSIX `sh`
and `tar` there. Where commands over ssh come without `XDG_RUNTIME_DIR`,
a session it starts uses `/run/user/<uid>` like a login would, and so do
the programs in its terminals.

Greed doesn't have to be installed on the other machine. The first time
you connect with a version, `greed ssh` puts the same version there, in
`~/.local/share/greed/server`, and uses it from then on. It copies the
greed you run when it runs there; otherwise, as when the other machine is
NixOS or an arm machine, it fetches that version's static build from the
releases and checks it against the release's checksums. A greed of the same
version already on the other machine's `PATH` is used as it is.

`GREED_REMOTE` sets the path of `greed` on the other machine, and nothing
is copied (the two ends check they speak the same protocol, and say so if
they don't); `GREED_REMOTE_BINARY` names a greed built for it to copy (like
`nix build .#static`'s, between releases). `GREED_SSH` sets the ssh
program to use. It's run as one program, so for options like a port use
`~/.ssh/config` or a small wrapper script.

### Your ssh agent

For a host your `~/.ssh/config` forwards the agent to (`ForwardAgent
yes`, as `ssh -G HOST` shows it), Greed brings your ssh agent along
itself. The session there has an agent socket of its own, which its
shells and terminals get as `SSH_AUTH_SOCK`, and each request on it goes
to the agent on the machine you're attached from. The socket stays the
same across reconnects, so `git push` in a shell that has been open for a
week reaches your keys after you come back, from this machine or another.
With nobody attached, a request fails at once. Greed turns ssh's own
forwarding off for its connection, so the session has one way to your
keys.

Before a program there signs with one of your keys, Greed asks on your
screen, and `y` allows it. Listing your keys doesn't ask. The
`ssh-agent-confirm` option says when to ask: `first` (the default) once
each time you attach, `always` every time, `never` not at all.

```luau
greed.option.set("ssh-agent-confirm", "always")
-- Some machines their own way, by the name of the machine the session
-- runs on: ask every time on the bastion, never on your own box.
greed.option.set("ssh-agent-confirm-hosts", "bastion=always devbox=never")
```

A zellij or tmux on that machine runs outside the session, with the agent
socket of whichever connection started it. Its shells can use the
session's socket instead, from their rc file:

```sh
export SSH_AUTH_SOCK=$(greed ctl agent-socket)
```

With several sessions there, `greed ctl agent-socket SESSION` names one.

While you're attached, anyone with root on that machine can use your keys
through the socket, as with `ssh -A`. Asking before each use (`always`)
means nothing signs without you pressing `y`.

## Editing

Greed has three editing styles, and you pick the one you like: Helix's
(select, then act), Vim's (act, then where) or modeless editing as in
VS Code. Greed asks the first time it starts, `:style vim` switches at any
time, and [Editing styles](editing-styles.md) has each one's keys and how
to make one your own.

Keys you type while a key's command is still working (say, on a slow
program) wait for it and then run in order, so typing ahead does what
typing slowly would. They wait half a second at most; `esc` and `ctrl-c`
reach a working command at once, unless keys typed before them are
still waiting.

Messages show on the status line, one line each; a longer one, like an
error with its stack trace, ends in `…`. `:messages` shows the last ones
in full.

This page shows the Helix style, Greed's default. In the Helix style you
select text, then say what to do with it. There is always a selection; a
cursor is a selection one character wide.

**Moving and selecting** (normal mode)

| Keys | |
|---|---|
| `h j k l`, arrows | Move |
| `w` `b` `e` | Select to the next word, previous word, word end |
| `W` `B` `E` | The same for WORDs, which include punctuation (`a.b`) |
| `f` `t` + a character | Select to the next one, or up to it; `F` `T` go back |
| `x` | Select the line; again, the next one too |
| `g g` `g e` | Start of the file, start of its last line |
| `G`, `5 G` | The last line, or line 5 |
| `g h` `g l` `g s` | Start and end of the line, first character that isn't a space |
| `m m` | The matching bracket |
| `g w` | Label every word on screen; type a label to jump there (`jump-label-alphabet` sets the letters, easiest first) |
| `;` `alt-;` | Collapse the selection to the cursor, swap its ends |
| `ctrl-h` `ctrl-k` | Back to the selection before the last command, and forward again |
| `%` | Select the whole file |
| `ctrl-f` `ctrl-b` | A screen down or up (also `pagedown` `pageup`) |
| `ctrl-d` `ctrl-u` | Half a screen down or up |
| `z z` `z c`, `z t`, `z b` | Put the cursor's line in the middle, at the top or at the bottom of the screen |
| `z j` `z k` | Scroll a line down or up; `Z` keeps the view keys going until `esc` |
| `g t` `g c` `g b` | The top, middle or bottom line on the screen |
| `g n` `g p`, `g a`, `g m` | The next or previous open file, the one you were in before, the one you changed last |
| `g .` `g \|`, `g f` | Where the file last changed, column N (`8 g \|`), the file named under the cursor |
| `alt-.` | Do the last `f` or `t` again |
| `ctrl-o` `ctrl-i` | Back to where the last jump (a search, `g g`, `g d`, a file you opened from anywhere, the shell included) started, and forward again, like a browser's back and forward. Each pane has its own, and going back puts the cursor and scroll where they were (`ctrl-i` needs a terminal that tells it from `tab`, as most do now) |

`:set line-numbers relative` numbers the lines by how far they are from the
cursor's line, so the line marked 5 below is `5 j` away. `hybrid` does the
same with the cursor's line showing its own number, and `absolute` goes
back.

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
| `>` `<` | Indent or dedent the lines by one level of the language's indent |
| `J` | Join lines with one space |
| `:reflow [WIDTH]` | Rewrap the selected lines to the `text-width` option (80), or WIDTH |
| `\|` | Pipe each selection through a shell command, a Luau filter or a model (below) |
| `space c`, `ctrl-c` | Comment the lines, or uncomment them |
| `=` | Format the file |
| `] space` `[ space` | Add an empty line below or above, staying put |
| `y` `p` `P` | Copy, paste after, paste before; copied lines paste above or below the line |
| `"` + a letter | Use that register for the next copy, paste, delete or macro, instead of the clipboard |
| `Q` `q` | Start or stop recording a macro, play it (`3 q` three times) |
| `:macro-save NAME [REGISTER]` | Keep the last macro as a command, in a `macros` plugin in your config that opens to edit |
| `u` `U` | Undo, redo |
| `alt-u` `alt-U` | Back or on through every state the text has been in, in the order it was made, including what an undo followed by an edit left on another branch |
| `space u t` | The undo tree: every state and branch; moving takes the text there, `enter` keeps it, `esc` goes back |
| `.` | Repeat the last change at the selections, with what it typed (`3 .` with a new count) |
| `esc` | Back to normal mode |

In insert mode, `tab` types a level of indent, `ctrl-w` (or
`alt-backspace`) and `alt-d` delete a word back or forward, `ctrl-u` and
`ctrl-k` delete to the start or end of the line, `ctrl-x` asks for
completions, and `ctrl-r` + a register inserts what it holds.

A number before a motion repeats it: `3 j`, `2 w`. It also counts for `x`
(lines), `p` and `P`, `u` and `U`, `>` and `<` (levels), `C` and `alt-C`,
and picks brackets further out with `m i (` and the like.

Some registers aren't storage: `"_` throws a copy away, `"+` and `"*` are
the clipboard, `"%` is the file's path, `".` what each selection holds,
`"#` each selection's number and `"/` the last search.

`|` asks what to pipe the selections through, and puts back what comes out,
each selection its own:

| Type | What it does |
|---|---|
| `sort -u` | Runs a shell command, with the selection as its input |
| `luau: snake_case` | Runs a Luau filter: `upper`, `lower`, `trim`, `snake_case`, `kebab_case`, `camel_case`, `pascal_case`, `sort`, `reverse`, or one you add with `require("@pipe").define` |
| `model: add doc comments` | Asks a language model (the `fast` role, or `:set pipe-model-role reasoning`) |

Helix's other shell keys work too: `!` puts what a command prints before
each selection and `alt-!` after it, `alt-|` gives each selection to a
command without changing it, and `$` keeps the selections a command
succeeds on (`$ grep -q TODO`).

All the selections change in one step, so `u` takes them back. A model's
changes are also an operation you can review with `space u o`, and if you
edit while the model works, the answers still land where the selections
were. See [Models](#models) to set one up.

New lines from `enter`, `o` and `O` start at the indent the code calls
for: a level in inside a block, bracket or `let`, and lined up with the
block's first line before its `}` or `end`. Between a pair of brackets,
`enter` puts the closing one on a line of its own. Languages without a
grammar keep the line's indent, one level more after an opening bracket
(or a `:` in Python and YAML), and so does code that doesn't parse yet,
like a Ruby `def` before its `end`, going by the language's keywords
(`indent_after` and `outdent_before` in its entry). A line holding just a
closer like `end`, `else` or `}` lines up with its block when you press
`enter` on it, and a closing bracket does as you type it at a line's
start. Each language has its own indent, like two
spaces in Nix or a tab in Go, set with `require("@languages").set("nix",
{ indent = 4 })`; the `indent` option is for files in no language. Tabs
show 4 columns wide; a language's `tab_width` changes that for its files
(`require("@languages").set("go", { tab_width = 8 })`), and `:set
tab-width 8` for the rest. A file gets its language from its name;
`:language NAME` gives a buffer another one (`:setf` too, as in Vim), and
`:language` alone says which it has. `:reindent-lines` indents the selected
lines again the way the language says, for code pasted in at the wrong
indent.

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
| `X` `alt-x` | Extend each selection to whole lines, or shrink it to the whole lines inside |
| `alt-_` | Merge selections that touch (`:merge-selections` merges them all) |
| `_` `&` | Trim spaces off the selections, line them up at one column |
| `alt-(` `alt-)` | Rotate what the selections hold, back or forward |
| `ctrl-a` `ctrl-x` | Add to or subtract from the number at each cursor (`5 ctrl-a`) |
| `v` | Select mode: moves extend the selection, `n` `N` add the next match as another selection; it lasts until you change or copy the text |

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
| `m i m` `m a m` | Inside or around the nearest brackets or quotes, whichever they are |
| `m i x` `m a x` | Inside or around the XML or HTML element |
| `m i n (` `m i l (` | Inside the next or last pair after or before the cursor (`m a` for around); any bracket or quote |
| `m i i` `m a i` | The lines indented as far as this one, or with the line above too |
| `m i d` `m a d` | The number at or after the cursor, or with its sign |
| `m i g` `m a g` | The change since the last commit under the cursor, or its whole lines |
| `m s (` | Wrap each selection in brackets, quotes, or any character |
| `m d (` | Take away the brackets or quotes around each selection |
| `m r ( [` | Swap them for others |

**By syntax**, in languages Greed has a grammar for (`:health` lists them):

| Keys | |
|---|---|
| `m i f` `m a f` | Inside or around the function |
| `m i t` `m a t` | Inside or around the type: a struct, enum, impl or table |
| `m i a` `m a a` | An argument or parameter, around with its comma |
| `m a c` | The comment |
| `m i T` `m a T` | Inside or around the test (Rust, Python, Go, JavaScript and TypeScript) |
| `m a e` | An entry in a table, map or struct |
| `] f` `[ f` | The next or previous function; also `t`, `a`, `c`, `T` and `e` |
| `alt-o` `alt-i` | Grow the selection to the syntax node around it, or shrink it back |
| `] n` `[ n` | The next or previous node beside it (Helix has these on `alt-n` `alt-p`, which are pane keys here) |
| `alt-a` `alt-I` | Every node beside it, or every node inside it |
| `alt-shift-right` `alt-shift-left` | Move the selected node past the next or previous one: swap arguments, list items, statements |
| `alt-b` `alt-e` | The start or end of the node around it |
| `space s` | Jump to a function or type in the file |

In Vim's style the same objects are `if` `af`, `ia` `aa` and `ic` `ac`, as in
`daf` or `cia`, and the next/last, indent and number objects are `in(`
`il(`, `ii` `ai` and `id` `ad`, as in `cin(` or `dii`.

**Folding**

| Keys | |
|---|---|
| `tab` or `z a` | Fold the block the cursor is in under its first line, or unfold it |
| `shift-tab` | Unfold everything when anything is folded, or else fold every outermost block |
| `z C` `z o` | Fold it, or unfold the folds the cursor is in (`z c` in the Vim style) |
| `z R` | Unfold everything |

A block is the smallest function, body, table or similar around the
cursor's line, from the language's grammar. In a language without one,
it's the lines indented under the nearest line indented less, and in
Markdown it's a fenced code block, a list item with lines under it (a todo
and its subtasks) or the section under a heading, whichever is innermost.
Vim's style folds with `tab`, `z a`, `z o`, `z R` and `z c` (it has no
`z C` or `shift-tab`), and also `z M` to fold every outermost block, `z f`
+ a motion to fold those lines, `z j` `z k` to go to the next or previous
fold, and `z d` `z E` to unfold.

If you'd rather edit like Vim, or without modes, `:style vim` and `:style
vscode` switch to those; [Editing styles](editing-styles.md) explains each.

**Prose**: `m i p`, `m i s` and `m i h` select a paragraph, sentence or
Markdown section (`m a ...` includes the space around it), and `] p` `[ p`,
`] s` `[ s` move between them.

## Searching

| Keys | |
|---|---|
| `/` `?` | Search forward or back as you type |
| `n` `N` | Next and previous match |
| `*` | Search for the selected text, exactly as written; a whole word only matches whole words |
| `alt-*` | The same, also inside longer words |
| `space /` | Search the whole project as you type |

Patterns are regexes. How searches you type mind case is one option,
`search-case`: `"smart"` (the default) ignores case unless what you type
has a capital letter, and `"ignore"` and `"match"` always do one thing.
It covers searching a file, the project search, `:g` and the pickers'
fuzzy matching. A few kinds of search have their own option, with the
default that suits them, which `"default"` hands back to `search-case`:

| Option | Default | |
|---|---|---|
| `notes-search-case` | `"ignore"` | Searching notes (`space n /`) |
| `substitute-search-case` | `"match"` | `:s`, as in Vim; its `i` and `I` flags still say otherwise for one run |
| `shell-filter-search-case` | `"ignore"` | `/` on a shell block's output |

```luau
local option = require("@greed").option
option.set("search-case", "ignore") -- every search ignores case...
option.set("substitute-search-case", "default") -- ...:s too
```

In the project search, `enter` opens a match and `ctrl-e` puts what was
found in a panel, a third of the screen wide: a multibuffer, with each
matching line under its file's name and beside its line number. Edit
those lines with any of the editing keys above (`s` to select the
matches, then `c` to change them all) and the files change as you type;
`:w` saves them, `enter` goes to the line and `q` closes the panel. A file
that changed on disk since the search is left alone and reported. `:grep
PATTERN` fills the panel directly.

## Files and buffers

| Keys | |
|---|---|
| `space f` | Find a file in the project; in your home folder, not under Library, Music, Movies, Pictures, Applications or Public |
| `space F` | Find a file under the folder Greed was started in |
| `space '` | Open the last picker again |
| `space .` | What you can do with what's under the cursor (a file, link, symbol, problem, change or the selection), to pick one; `alt-.` in the vscode style |
| `space b` | Switch to an open file |
| `space space` | Switch to anything open: files, shells, terminals and other buffers, each saying what it is. `@shell` (or `@sh`) keeps one kind, `@modified` those with unsaved changes, `@shown` those in a pane; the preview shows a shell or terminal at its end. `enter` shows it here, `ctrl-v` beside, `ctrl-s` below and `ctrl-f` in a float |
| `space j` | Pick a place from the jumplist |
| `space y` `space p` `space R` | Copy, paste and replace, as in Helix (copies always go to the clipboard here) |
| `space e` | File tree in a side panel |
| `:w` `:w PATH` | Save, or save as; an untitled buffer asks where to save it |
| `:wa` (`:write-all`) | Save every file with unsaved changes |
| `:e PATH` | Open a file |
| `ctrl-s` | Save, in every style |
| `:b NAME` | Switch to the open file whose path is NAME or has it in it; `:b#` (or `ctrl-^` in normal mode) goes back to the one before |
| `:ls` (`:buffers`) | Pick an open file, like `space b` |
| `:bn` `:bp` | Next and previous open file |
| `:bc` (`:bd`) | Close the file; the one you were in before takes its place. `:bc!` closes it with unsaved changes |
| `:bco` | Close every other file |
| `:close` | Close the pane (the file stays open), like `alt-p x`; `:only` closes the others |
| `:sp` `:vs` `:new` `:vnew` `:tabnew` | Split the pane, or open a new pane or tab, as in Vim |
| `:reload` (`:rl`), `:rla` | Load the file again from disk, or every open file |
| `:noh` | Take away search highlights |
| `:set NAME VALUE` | Set an option. Yes-or-no ones also take Vim's `:set NAME`, `:set noNAME` and `:set NAME!`, `:set NAME?` (or `:get NAME`) shows one, and `:set nu`, `nonu`, `rnu` and `nornu` show and hide line numbers. Vim's `tw`, `ic` and `scs` work too. `:toggle NAME` flips one, as in Helix. A name that isn't an option gets the names like it |
| `:stalls` | The times plugin code held the editor up, with the plugin and what it was doing |
| `:errors` | Errors from plugin code that nothing caught, newest first: the plugin, what it was doing, the message and where in its code it failed |
| `:profile` | Start counting where the editor's time goes; again, stop and show it by plugin and what it did |
| `:debug TOPICS` | Turn debug topics on (`:debug keys frames`) or off (`:debug -keys`, `:debug off`); alone, says which are on. See [Debugging](#debugging) |
| `:debug-log` | What the debug topics on have said, in a pane below that follows new lines |
| `:secret-set NAME` | Keep a secret, like an API key, in the system keyring (or Greed's own secrets file where it can't be reached); what you type shows as dots |
| `:login PROVIDER`, `:logout PROVIDER` | Sign in to a model provider: with an account for plans that come with one, like Berget Code, or else with its API key, like Mistral (see [Models](#models)) |

Closing a terminal's buffer ends its program.

Saving writes a new copy of the file beside it and moves it into place, so a
crash or a full disk never leaves a file half written. The file keeps its
permissions, and saving through a symlink writes the file it points to. A
file that isn't UTF-8 opens read-only, with what can't be read shown as `�`,
and `:w` refuses to write over it, since that would replace those bytes;
`:w PATH` saves what you see to another file.

`greed bench [FILE]` measures how quickly keys show: it starts a session
with your plugins and config on the file (a large generated Rust file
without one), types and moves around as you would, and prints how long
each kind of key took from leaving the client to the frame showing it
arriving, with the slowest named, and where the time went per key (as
`:profile` shows it). It types into a terminal too, timing each character
until its echo shows. `greed bench --draw` also draws each frame in the
terminal you run it in, the way `greed` does, and says how long that took,
how many bytes went out, and how long your terminal took to take them in.

`greed shot [FILE]` saves the editor as the window would show it, with
your plugins and config, as a picture: for a bug report, or to show a
setup. Steps before it go in order: `--keys "space e"`, `--type TEXT`,
`--run COMMAND`, `--wait SECONDS` and `--wait-for TEXT` (until the screen
shows it), then `--size 1280x800` and `--out PATH` (`greed-shot.png`). It
needs no window, but a GPU or software Vulkan to draw with. `--run` takes
a command's name alone; for one with arguments, type it at `:` as you
would: `--keys ":" --type "board ops" --keys enter`.

`greed --record SCRIPT [FILE]` records the editor the same way, every
frame a picture, for a video or a set of screenshots. The script has a
step a line, and `#` starts a comment:

```text
size 1280 800          the pictures' size, before any step
scale 2                pixels per point, for sharper pictures
fps 30                 frames a second
typing 0.04            seconds between the keys `type` presses
output media/shell     where the frames and screenshots go (beside the script)
hide                   stop keeping frames, while setting things up
show                   keep them again
keys space f           press keys, named as in keymaps
type kubectl get pods  type text, a key at a time
run shell              run a command
wait 1.5               let seconds pass
wait-for Running       wait until the screen shows the text (10 seconds at most)
shot pods              save the screen as pods.png
```

The frames go in `frames` under the output folder, numbered, to make a
video of with ffmpeg: `ffmpeg -framerate 30 -i frames/%05d.png -pix_fmt
yuv420p demo.mp4`.

In the file tree, `enter` or `l` opens a file or folds a folder, `h` folds
the folder you're in, `r` reads the disk again and `q` closes it. `a`
makes a file in the folder under the cursor (end the name with `/` for a
folder), `R` renames or moves what's under the cursor, taking files you
have open along, and `d` deletes it once you press `y`. A click does what
`enter` does, and the row under the mouse lights up.

Without the tree, `:file-rename NAME` renames the file you're in (a path
moves it, from the project's root), and `:file-delete` deletes it once
you press `y`.
`:set tree-icons nerd` shows an icon by each name (see [Icons](#icons)).

When a file changes on disk, from another program or an agent, its buffer
loads the change as an edit you can undo with `u`. A buffer with unsaved
changes is left alone and Greed tells you; `:reload` loads the file into it
anyway. `:set auto-reload false` stops loading changes by itself.

`:set auto-save true` saves files on their own a second after you stop
editing them, so a burst of typing is one save; `:set auto-save-delay 3000`
waits three seconds instead. Put it in your `init.luau` to keep it:
`require("@greed").option.set("auto-save", true)`.

### Icons

The file tree's icons and the status line's rounded ends come from
[Nerd Fonts](https://www.nerdfonts.com). The window (`greed --gui`) has
them built in, so they show whatever font you draw in, even when another
installed font claims the same characters. A terminal shows them only if
its own font has them: install a Nerd Font, or one of its icon-only
"Symbols" fonts, and set your terminal to use it. Without one you see
boxes where icons should be.

In the window, emoji come from your system's emoji font; one it can't draw
in color, like the newest Noto Color Emoji, is passed over for another, or
the plain Noto Emoji.

Two options use them. Out of the box you see plain text that works
anywhere: `tree-icons` is `"none"`, and the rounded ends show only once
`statusline-pills` is on (see [The status line](#the-status-line)).

```luau
local option = require("@greed").option
option.set("tree-icons", "nerd") -- "none" for no icons
option.set("statusline-caps", "round") -- "none" for square ends
```

Setup turns icons on when you run it in the window, or when you say a
terminal shows them. The same config works for the window and terminals,
so if you set Greed up in the window and later use a terminal without a
Nerd Font, set both options back to `"none"` in your `init.luau`.

## Debugging

When something feels off, like keys going missing or a pause, debug topics
say what happens inside, and `:debug-log` shows it as it comes. Turn on
what you're after, do the thing again, and read the log:

| Topic | What it says |
|---|---|
| `keys` | Each key from each client, what it ran (or that it isn't bound), and how long it waited behind a command at work |
| `runs` | Every run of plugin code: the plugin, what it ran, how long it took |
| `frames` | Each frame built for a client, how long that took, and whether all of it was sent or what changed |
| `rpc` | Messages to and from language servers and other JSON-RPC programs |
| `jobs` | Programs plugins ran, how long they took and how they ended |
| `client` | The terminal's or window's side: keys and input method events as the system gave them, focus, and how long drawing each frame took |
| `plugins` | What plugins say with `greed.debug.log`; `plugin:NAME` for one |

`:debug keys client` turns two on, `:debug -client` one off, `:debug off`
all of them, and `:debug all` everything. A topic that's off costs next to
nothing, so they can stay in a release build; one that's on keeps its last
10 000 lines in memory. To catch what happens at start, set them in your
`init.luau` (`greed.debug.switch("keys frames")`), or start with
`GREED_DEBUG=keys,frames greed` (a session started in the background gets
it too). Agents and scripts read the same lines with `greed ctl debug_log`
(`set=keys` turns topics on, `after=ID` reads only newer lines).

## Language servers

Greed knows the usual languages and their servers and starts a server when a
file needs one and it's installed. `:health` shows each language's server,
whether it was found, and the servers running. Without a server nothing
complains until you ask for something only a server can answer, like `g d`;
then it says which program to install.

Each project gets a server of its own, so files from two projects (or two
jj workspaces of one) are checked separately. A server runs in the topmost
folder of the file's project that has one of the language's root files
(`Cargo.toml` for Rust, `package.json` for TypeScript), so one server covers
a whole Cargo or npm workspace; without one, it runs in the project's root.
A server that crashes starts again, up to three times in a row, and
`:lsp-restart` starts this file's server again when it's stuck
(`:lsp-restart all` every one). Servers that support it hear only what
changed with each edit, so big files stay quick.

| Keys | |
|---|---|
| `space k` | What's under the cursor, with any problems there |
| `g d` | Go to the definition |
| `g D` `g y` `g i` | Go to the declaration, the type's definition, an implementation |
| `g r` | Pick a place it's used, with a preview |
| `space H` | Select every place in this file it's used (Helix's space h, which is help here) |
| `space S` | Pick a symbol anywhere in the project |
| `:rename` | Rename it everywhere it's used (`space r`; also `g r n` in the Vim style, `f2` in the vscode style) |
| `space a` | Pick a fix or refactor for the cursor or selection |
| `space d` | Pick a problem in this file |
| `space D` | Pick a problem in any file the server checked, open or not |
| `] d` `[ d` | Next and previous problem; `] D` `[ D` the last and first |

Problems are underlined, and their lines get a sign and a colored line
number. Each line's worst problem also shows after the end of the line;
`:set diagnostic-messages false` hides those. They move with your edits
until the server checks the file again.

In the `g r` and `space D` lists, `ctrl-e` puts the places shown in a panel
like the project search's: each reference with a line around it, or each
problem's line with its message beside the file name (two on one line get
a line each, and one too long for the panel ends in `…`). Edit them there the
same way.

A rename or code action that changes other files opens them without showing
them and leaves them unsaved, so you can look the change over (`space b`)
and undo it before saving.

Completions show as you type, in a menu at the cursor, once typing pauses
after a letter or a `.`. The menu narrows as you keep typing, with what
starts with what you typed first, then what holds it, then looser matches.

| Keys | |
|---|---|
| `tab` `ctrl-n` `down` | Next completion |
| `shift-tab` `ctrl-p` `up` | Previous completion |
| `enter` | Put the current one in |
| `esc` | Close the menu (and leave insert mode) |
| `ctrl-space` | Ask for completions now (in the vscode style it opens the leader instead) |

These apply to every completion menu, the shell's included:

- `completion-delay` (150) is how many milliseconds typing pauses before a
  menu opens by itself; `:set completion-delay 300` waits longer, and `0`
  opens it only when you ask, with `ctrl-space` (or `tab` in the shell).
  Asking always shows it at once.
- `completion-enter` says what `enter` does in a menu: `first` puts in the
  first item, `selected` only an item you moved to with `tab` or the
  arrows, and otherwise `enter` does its usual job, like starting a new
  line or running a shell's line. `auto`, the default, lets each menu say:
  a language server's takes the first, [the shell's](shell.md#history-and-completion)
  only one you chose.

In Vim's style, `ctrl-n` and `ctrl-p` in insert mode complete from the
words in open files.

Typing `(` or `,` in a call shows what the function takes, above the
cursor, with the parameter you're on picked out. It follows along as you
type and closes when the call does or you leave insert mode. To ask for it
with a key, bind `signature-help` in insert mode, e.g.
`greed.keymap.bind({ role = "typing" }, { ["ctrl-k"] = "signature-help" })`.

## Version control

In a jj or git repository, lines added (`+`), changed (`~`) and removed
(`-`) get a sign beside them. With jj that's against the working copy's
parent, so the signs show what your current change does. With git it's
against what's staged, so a change loses its sign once you stage it.

| Keys | |
|---|---|
| `] g` `[ g` | Next and previous change; `] G` `[ G` the last and first |
| `space g r` | Put the change under the cursor back the way it was |
| `space g a` | Stage the change under the cursor (git) |
| `space g b` | Who last changed this line, and when |
| `space g w` | Why the selected lines are as they are: each change that made them, with its description and diff |
| `space g g` | Pick a file changed since the last commit |
| `space g s` (`:changes`) | Every change in the project, in one buffer |
| `space g S` (`:staged`) | What's staged, to unstage hunks and commit (git) |
| `space g l` (`:change-stack`) | The change stack: describe, split, squash, move and abandon changes |

`:set vcs-signs false` hides the signs.

`space g s` shows each change in every file, with a couple of lines around
it: added lines in green, and removed ones in red where they were, under
each file's name. With git it shows what's not staged yet. It's a
multibuffer like the project search's results, so you can edit the
changes there and `:w` saves the files; `space g r` on a change puts it
back, `space g a` stages just that change, and `enter` goes to it in its
file. New files show whole, and deleted ones are left out.

`space g S` shows what's staged as a diff: `u` on a hunk unstages it, `c`
commits with a message you type, `r` reads it again and `q` closes it.
jj has no staging area; split a change in the change stack instead.

`space g l` lists your changes with jj, newest first: from the working
copy (`@`) down to the last immutable change (`◆`), with their bookmarks
and descriptions. On the change under the cursor:

| Keys | |
|---|---|
| `enter` | Show its diff; `q` goes back |
| `d` | Describe it |
| `n` | Start a new change on top of it |
| `e` | Make it the working copy, to edit it |
| `s` | Squash it into its parent, keeping the parent's description |
| `S` | Split it: pick the hunks for a new change before it |
| `a` | Abandon it, after asking |
| `alt-k` `alt-j` | Move it up or down the stack |
| `u` | Undo the last jj operation |
| `r` | Read the stack again |
| `q` | Close it |
| `?` | A menu of these keys |

In a git repository it lists the last 30 commits, and `enter` shows one.

## Operations

An operation is a piece of work across files taken as one thing: a
rename an agent did in 14 files, a plugin's refactor, the changes you
accepted from a proposal. Its edits in every file undo together, and you
can review it in one buffer.

| Keys | What it does |
|---|---|
| `space u o` (`:operations`) | Pick a recent operation to review |
| `space u u` (`:operation-undo`) | Undo the latest operation, in every file at once |
| `space u c` (`:operation-commit`) | Save the latest operation's files and commit just them, named after it |

The review is a multibuffer of the operation's changes, with the programs
it ran (a test run, a formatter) and how they exited at the top. Edit it
like any multibuffer, `space g r` puts a change back, and `space u u` in it
undoes that operation.

If you've edited its files since, undo keeps your edits: it puts back each
of the operation's changes you haven't touched, leaves the ones you have,
and says how many it left. Operations are kept across restarts (in the
cache folder), so you can still review and undo yesterday's agent work
the same way.

`space u c` turns an operation into a commit of its own (a jj change, or a
git commit): it saves the operation's files and commits only them, with the
operation's name as the message, so other changes you have going stay
where they were. In a review it commits the operation shown.

Every edit also records who made it (you, a plugin, an agent, or a change
on disk) and the command it came from. Agents can ask with the
`history_recent` tool, and plugins with `buffer:history()`.

## Models

Features that use a language model ask for a role, and you choose which
model plays it. Out of the box:

| Role | Model |
|---|---|
| `fast` | Claude Haiku 4.5, at Anthropic |
| `reasoning` | Claude Opus 5.5, at Anthropic |
| `local` | Llama 3.2, on [Ollama](https://ollama.com) on this machine |

Greed's own agent asks for `agent`, which uses `reasoning` until you set
it; reviewing code an agent wants to run asks for `review`, also
`reasoning` until set; and compacting a long conversation of Greed's agent
asks for `compact`, which uses `agent` until set.

`:models` shows every role, its model and whether its provider's key is
found, and lets you change them:

| Key | |
|---|---|
| `enter` | Pick the provider and model for the role under the cursor, from the models the provider lists; asks for the key if it needs one |
| `e` | Pick how hard the role's model thinks before it answers: `none`, `low`, `medium`, `high`, or unset |
| `k` | Set the API key of the role's provider: it goes in the system keyring, or Greed's secrets file where it can't be reached |
| `l` | Sign in to the role's provider, for those with an account instead of a key, like Berget |
| `q` | Close |

The model picker lists what the provider offers (for Ollama, the models
it has pulled), the role's current model or the provider's suggested one
first; type to narrow it down. A name that isn't listed can still be
typed: enter on one that matches nothing takes it as it is, and "type a
name…" asks for it. When the list can't be had, say without a key yet or
with the server down, Greed says why and asks for the name instead. Lists
are kept for ten minutes.

What you pick there is kept in Greed's data folder and comes back next
time. Your `init.luau` is read after it, so a role set there wins, and
`:models` says "(set in your config)" beside it. Instead of the key, you
can set the variable `:models` names, like `ANTHROPIC_API_KEY`, or run
`:secret-set anthropic`. Anything that needs a model and has no key says
the same: which variable sets it, and that `:models` adds one.

Keys and sign-ins go in the system keyring through `secret-tool` on Linux
(`security` on macOS). When Greed can't reach it, say in a session started
where `secret-tool` isn't installed or there's no D-Bus session, a key kept
there looks missing, so the message says the keyring couldn't be reached
and why. Keeping a key or signing in then goes to Greed's own secrets file,
and Greed says so; keys there are found whether the keyring answers or not.

`:usage` shows how many tokens the models were sent and wrote: today, by
model, and each day of the last week, as the providers reported them for
Greed's agent and the features with tools. Tokens read from the provider's
cache are shown apart, as "(52.1k cached)": they cost a fraction of the
rest, so a low share means caching isn't working. Under each model, how
many of Greed's agent's edits worked, by the way it made them. It's kept a
file a day in
Greed's data folder (`usage/2026-10-09.json`), by hour and model.

Ollama needs no key, but it has to run: `ollama serve` starts it, and
`ollama pull llama3.2` fetches a model. Greed says so when it can't reach
it or the model isn't there.

You can also set any of it in your `init.luau`, with OpenAI, Ollama or any
server that speaks OpenAI's chat completions API:

```luau
local models = require("@models")
models.roles.fast = { provider = "ollama", model = "qwen2.5-coder" }
models.roles.reasoning = { provider = "openai", model = "gpt-5" }
models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", secret = "work" }
models.roles.review = { provider = "work", model = "reviewer-1" }
```

A role or provider can also say how many tokens its model has room for,
as `context = 128000`. Greed knows that for well-known models by name and
assumes 32k for others; Greed's own agent uses it to compact long
conversations (see [Agents](agents.md#greeds-own-agent)).

A role's `effort` says how hard its model thinks before it answers:
`"none"`, `"low"`, `"medium"` or `"high"`. Unset, nothing is sent and the
model does what it does by default. `e` in `:models` picks it and keeps it
with the role, and the role's line shows it; a provider's `effort` is the
default for its roles. Servers with OpenAI's API get it as
`reasoning_effort`. A provider that takes only some sets `efforts`, and
the nearest of those is sent: the `mistral` provider takes `none` and
`high`, so `low` is sent as `none` and `medium` as `high`, and `:models`
says so. Claude models get it as their effort, with their thinking
summarised so Greed's agent can show it; models before Claude 4.6, like
Haiku 4.5, think within a budget instead (2k, 8k or 24k tokens). In Greed's
agent, `/effort` changes it for one session (see
[Agents](agents.md#slash-commands)).

```luau
models.roles.agent = { provider = "mistral", model = "mistral-large-4", effort = "high" }
models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", effort = "low" }
```

Greed's agent sends the whole conversation each turn, and providers charge
far less for the part they've seen before and cached. Some, like Mistral,
only cache a request that names its conversation: `cache_key = true` on a
provider has Greed's agent send its session's id as `prompt_cache_key`.
The `mistral` provider has it on. `:usage` shows how much was cached.

A provider with a `secret` reads its key with `:secret-set NAME`, or from
`GREED_SECRET_NAME`. The built-in providers send their keys only to their
own servers. The first time any other key would go to an address, Greed
asks (`y` yes, `n` no) and keeps your answer, so a plugin can't add a
provider that sends your key somewhere you didn't choose.

Some plans come with an account instead of a key, like Berget Code's fixed
monthly price. `:login berget` signs you in: it shows a link and a code,
you approve it in a browser on any device, and the `berget` provider uses
that sign-in from then on, renewing it as needed. `:models` says "signed
in"; `:logout berget` forgets it, and the provider goes back to its key.

```luau
models.roles.agent = { provider = "berget", model = "the model you want" }
```

For a provider that only takes a key, `:login` asks for the key:
`:login mistral` keeps a Mistral API key (or set `MISTRAL_API_KEY`), and
the `mistral` provider uses Mistral Large 4 for `reasoning` and Mistral
Small for `fast` when picked in `:models`:

```luau
models.roles.agent = { provider = "mistral", model = "mistral-large-4" }
```

| Keys | |
|---|---|
| `space i e` | Explain the selection (or the line) in a panel, as the answer arrives |
| `space i a` | Ask something about the selection |
| `space i f` | Fix the problem the language server reports on this line, as proposed changes to review |
| `space i c` | Draft a description of the changes in progress; `a` uses it (`jj describe`, or a git commit of what's staged) |

Fixes come like an agent's proposals: `] o` goes to each change, `space o a`
or `space o r` accepts or rejects it, and what you accept undoes as one
operation. These use the `fast` role; `:set assist-role reasoning` asks
another.

### The context

Pin what a model or an agent should see, and it goes with every question:

| Keys | |
|---|---|
| `space i p` | Pin the selection, or the whole file when nothing is selected; outside a file, what's under the cursor (a shell row, a block) |
| `space i i` | Show what's pinned, one item a line with its size in tokens; delete a line (`x d`) to drop it |
| `:context-add-problems` | Pin this file's problems from the language server |
| `:context-add-diff` | Pin the changes in progress |
| `:context-clear` | Drop everything |

Anything you can inspect pins too: `pin to context` is among the actions
of every object (`space .`, or the inspector), so a pod, a shell block or
a terminal can go with your messages, as its state is when you send each
one.

Items are read fresh each time they're sent: a pinned selection follows the
text as you edit, the diff is the diff as it is now, and a pinned pod is
its row from the newest block that lists it. The assist commands send the
context with each question. The agent pane sends it with a message when
it changed since the last one, so a pinned file goes again only after it
was edited; other agents read it with the `context_get` tool. Each
project keeps its own across restarts, except pinned objects, which
belong to the session.

## Formatting

Saving a file formats it, and `:format` does it without saving. Greed uses
the language's formatter when it's installed (`gofmt`, `ruff`, `stylua`,
`prettier`, `shfmt`, ...) and otherwise asks the language server, which is
how Rust gets `rustfmt` through rust-analyzer. Only what the formatter
changed is replaced, so your cursor stays put.

```luau
-- A different formatter for a language
require("@languages").set("python", { formatter = { "black", "-q", "-" } })

-- No formatting on save
require("@greed").option.set("format-on-save", false)
```

A formatter gets the text on its input and prints it formatted; `{path}` in
its command stands for the file's path.

## Markdown

Markdown files show as documents: headings without their hashes (a
top-level heading twice the size), `**bold**`, `*italic*`, `~~struck~~`
and `` `code` `` without their markers, links as their underlined text,
fenced code on a background of its own, quotes with a bar, `---` as a
line, list bullets (`-`, `*` or `+`) as dots and tables in aligned columns
with borders. Code blocks keep their markup: a `# comment` there is code,
not a heading. The file stays plain Markdown: while you type on a line
(insert mode) it shows as written, and in the vscode style markup shows
once the cursor is inside it. The window draws big headings big and sets the text in a proportional font
(code and tables stay monospaced); terminals other than kitty show
headings at the normal size.

`:set markdown-look false` turns the look off everywhere. To see one file
as written, or one file as a document while the option is off, toggle it
for that file with `space m l` (`alt-V` in the vscode style, or
`:markdown-look-toggle`). The status line shows `markdown · plain` while a
file shows as written.

### Reading view

`space m v` (`alt-v` in the vscode style, or `:markdown-read`) shows the file for
reading: read-only, without line numbers, and with no markup showing
anywhere, even on the cursor's line. Images on a line of their own show in
place (in the window, and in terminals that show images; elsewhere you see
their description), and links show as their text. `esc`, `q` or the same
key again goes back to editing, at the same place.

| Keys | |
|---|---|
| `j` `k` `h` `l`, arrows | Move |
| `pagedown` `pageup`, `ctrl-f` `ctrl-b`, `ctrl-d` `ctrl-u` | Page and half page |
| `/`, `n`, `N` | Search |
| `enter` or a click on a link | Follow it |
| `esc`, `q` | Back to editing |

A link to `#a-heading` goes to that heading, a link to another Markdown
file opens it in the reading view too (at its heading, with
`other.md#a-heading`), a web or mail link opens in your browser or mail
program (the `link-opener` option says which), and a `file://` link opens
the file in Greed. Links of other kinds, which any file you read could
hold, don't open.

### Choices

A list whose items start with `( )`, one of them `(x)`, is a set of
choices. They show as ◯ and ◉ (round buttons in the window), and pressing
one (a click, or `enter` on it) picks it and unpicks the others. The answer
is the text itself, so it reads the same anywhere:

```markdown
How do you like to edit?

- (x) Helix: select first, then act
- ( ) Vim: say what, then where
```

Picking only changes the text. Plugins read the answers and act on them
(see [Writing plugins](plugins.md)), and so can code blocks in the file
(below).

### Questionnaires

Choices and runnable blocks together make a page of questions that does
things, which still reads as plain Markdown anywhere. Comments, which
GitHub and the like don't show either, hold what makes it work:

````markdown
Which theme? <!-- id=theme -->

```luau output=choices
return require("@theme").list()
```

```luau when=theme
require("@theme").use(answer)
```

Will you use agents? <!-- id=agents -->

- (x) Yes
- ( ) No

<!-- if agents=yes -->
Which language model? <!-- id=provider -->

- ( ) Anthropic
- ( ) Ollama: on this machine <!-- value=ollama -->
<!-- end -->

```luau button="Save"
require("@greed").echo(`theme {answers.theme}, model {answers.provider}`)
```
````

- `<!-- id=NAME -->` on a question names it. Its answer is the picked
  option's value: its text up to the first `:` ("Ollama"), or a
  `<!-- value=... -->` on the option.
- A block with `output=choices` writes the choices it returns (a list, or
  one per line; `(x) ` in front picks one) under itself, and running it
  again keeps your pick. In a file you trust, these run as it opens.
- A block with `when=NAME` runs each time that question's answer changes,
  with `answer` set to it.
- A block with `button="Label"` shows as a button, and runs when pressed.
- Every block gets `answers`, each named question's answer (programs get
  them as JSON in `ANSWERS`, and `ANSWER`).
- `<!-- if NAME=VALUE -->` to `<!-- end -->` is a part that shows only for
  that answer (`!=` for any other), or for any of several, as in
  `<!-- if style=vim,helix -->`. Its questions don't count otherwise.

Blocks that make choices or hear picks hide behind the page, and buttons
show as buttons: put the cursor there to see their code. They run as any
block does: in a file you haven't trusted, the first asks whether to. A
Luau block can't wait, so one that asks for something, like a prompt or a
secret, does it in `greed.spawn`. Greed's own setup page is a questionnaire
like this: `setup.md` in the `setup` plugin.

### Runnable code blocks

A fenced block in a language Greed can run runs when you ask, and its
output is saved in a `result` block right under it. That way the file
shows the output anywhere, from GitHub to your phone, and a diff shows
what changed. Running a block again replaces its result.

[![A note with a live load chart under a shell block, and a block filtering another block's table of pods](https://github.com/johnae/greed/releases/download/media/notes.png)](https://github.com/johnae/greed/releases/download/media/notes.mp4)

````markdown
```sh id=files
ls *.md
```

```result
README.md
using.md
```
````

| Keys | |
|---|---|
| `space m r`, or `enter` on the fence once it shows `▶ run` | Run the block under the cursor |
| `space m R` | Run every block in the file, in order |
| `space m c` | Clear the block's result (`:blocks-results-clear` clears them all) |
| `space m s` | Stop the block running under the cursor |

Blocks run as `shell`, `sh`, `bash`, `zsh`, `fish`, `python`, `node`,
`ruby`, `luau` and `http`:

- A `shell` block runs in the Greed shell, a line at a time, stopping at
  one that fails, so table stages and `| chart` work as they do there. A
  chart shows in colour, and as an image in the window and terminals that
  draw one. With `every=SECONDS` its line runs again that often and the
  result keeps up, without filling undo, until `space m s` stops it; the
  fence shows `● live` meanwhile.

- A program gets the code to run, and prints the result. When it fails,
  the result block says how it exited (`result exit=1`).
- A `luau` block runs in the editor, with the whole API: its result is what
  it prints and what it returns. A one-line expression like `6 * 7` is its
  own result.
- An `http` block is a request: the method and URL on its first line (or
  just a URL, for GET), then header lines, then after a blank line the
  body. The result is the status and the body; `headers=true` adds the
  response's headers.

Options go after the language:

- `id=NAME` names a block, and `input=NAME` gives another block that
  block's result: on stdin for a program, as `input` in Luau, and into
  the first line of a `shell` block, so `where STATUS != Running` alone
  works on it. The named
  block runs first if it has no result yet, so a page of blocks works like
  a small pipeline. With `rerun=true` on the block taking the input, its
  input runs again every time, so it never reads a stale result.
- `dir=PATH` runs a program in another folder than the file's.
- `timeout=SECONDS` stops it after that long.
- `every=SECONDS`, on a `shell` block, keeps it live (above).

While a block runs, its fence shows `■ running`; click that or press
`space m s` to stop it, along with anything it started, like a server. A
result keeps at most `blocks-max-lines` lines of output (1000).

Nothing runs when a file opens. The first time you run a block in a file,
Greed asks whether to: `y` for now, `a` to always trust that file
(`:blocks-untrust` takes it back). Trusted files, and files whose front
matter says `greed: run`, show a `▶ run` button after each block's fence.
Front matter only shows the buttons; running still asks. The status line
shows `markdown · blocks` when they're on. Agents can list and run blocks
too (`blocks_list`, `blocks_run`), but only in files you trust, and only
blocks as they were when you last ran them yourself or trusted the file
(`a`, or `:blocks-trust`). A block an agent changed, in the buffer or on
disk, doesn't run for an agent until you've run it, and neither does a
block taking its input from one.

Add a language from Luau:

```luau
local blocks = require("@blocks")
blocks.runner("lua", blocks.program({ "lua", "-e" }))
```

## Notes

Notes are Markdown files in a folder (`~/notes` unless you set
`notes-folder`), so git or Syncthing can carry them between machines and to
your phone. Link one to another with `[[name]]`, or `[[name|other words]]`
to show other words.

| Keys | |
|---|---|
| `space n d` | Today's note, in `daily/` |
| `space n c` | Add a todo to the inbox, from wherever you are: the project's when it keeps notes, otherwise yours (`:notes-capture-mine` always yours) |
| `space n a` | The agenda: open todos from every note, soonest due first |
| `space n f` | Find a note; a name that isn't one yet makes it |
| `space n /` | Search every note as you type |
| `space n x` | Tick a todo or untick it; a plain line becomes one |
| `space n t` | Jot a thought or an idea down in the inbox, with today's date: for things that aren't todos |
| `space n r` | Dismiss the reminders notice (below) |
| `space k` | On a due date or a reminder, say when it is in words ("tomorrow, 18:00, in 25 hours") |
| `space n l` | Have Greed's agent connect the inbox (or the note you're in) to your other notes (below) |
| `g d` | Follow the link under the cursor, making the note if it's new |
| `z a` | Fold the section under the cursor, or unfold it (any Markdown) |

A todo is a list item with a box, `- [ ] call the bank`, and
`due:2026-10-03` anywhere in it gives it a date for the agenda. Notes and
todos are objects too: `space h i` on one shows its note, due date and
reminder, and `space .` opens or ticks it, for agents as well. In a note,
links show without their brackets (except while typing on their line) and the
notes linking to it are listed at its end. Other Markdown files, like a
project's README, look as they always do; `:set notes-everywhere true`
treats every Markdown file as a note, and `:set notes-conceal false` shows
the brackets and the markup below as written.

```luau
require("@greed").option.set("notes-folder", "~/Documents/notes")
```

### Reminders

Put `remind:2026-10-06 18:00` on a todo, or on any line of a note, and
Greed reminds you then. A date alone, `remind:2026-10-06`, goes off at
09:00 (`:set notes-remind-time 08:30` to change it). Times are your
computer's local time. Ticked todos don't remind you.

When a reminder comes due:

- A notice opens at the top right and stays until you dismiss it with
  `space n r`. Click a reminder in it to open its note at that line.
- Your desktop shows a notification, with `notify-send` on Linux or
  `osascript` on macOS, when they're installed. `:set notes-remind-desktop
  false` turns this off.
- In a terminal that isn't focused, Greed also sends the terminal's
  notification escape and a bell, so the terminal can tell you even over
  `greed ssh`. Terminals that understand it (kitty, WezTerm, Ghostty,
  iTerm2, foot and others) show a notification of their own. Inside tmux
  only the bell gets through, and only with tmux's `focus-events` on. When the
  terminal and `notify-send` both show one, `:set notes-remind-desktop
  false` leaves only the terminal's.

Reminders that came due while Greed wasn't running show the next time it
starts. Greed remembers which ones went off in its cache folder, so each
goes off once.

The status line says how many todos are due today, like `2 due today`, in a
warning color when some are overdue (`1 overdue, 2 due today`). Click it to
open the agenda.

Agents can set reminders too: ask Greed's agent to "remind me this evening
to call the bank" (see [Agents](agents.md)).

### Connecting your notes

Jot thoughts and todos down as they come (`space n t`, `space n c`), then
let Greed's agent make sense of them: `space n l` has it go through your
inbox, or the note you're in, find the notes each item relates to, link
them with `[[name]]` and add a line of context. It changes notes that are
there only as proposed edits you accept or reject one by one, makes new
notes for items that belong together, and ends with a summary. It uses the
model playing the `agent` role.

Any agent can work with your notes the same way through the `notes` tool
group (see [Agents](agents.md#tool-groups)); `:set agent-tool-groups "plan
notes"` gives it to every agent from the start. Agents reach only the notes
in your note folders, by name: `../x` and other names leading out of them
are refused. Rewriting a note that's there comes to you as a proposal,
adding a line or a todo goes straight in, and decisions can only be
proposed with `decision_propose`.

### Notes in a project, and other places

A project can keep notes of its own in `.greed/notes/` (or wherever
`notes-project-folder` says, inside the project). Make the folder and its
notes count: they're found, searched and linked with yours, their todos
are in the agenda, and capture puts todos in the project's inbox. Their
names start with `project:`, like `project:plan`; a link in a project note
goes to a note beside it first, so `[[design]]` there means
`project:design` when there is one. The plan and decisions you share with
agents (see [Agents](agents.md#a-plan-and-decisions-you-share)) are notes
there too. Commit the folder to share it, or leave it out of the
repository to keep it yours.

More folders of your own, each with a name for its notes:

```luau
require("@notes").add_place("work", "~/work/notes") -- notes named work:NAME
```

### How notes look

A note's markup shows as symbols: todo boxes as ☐ and ☑ (real checkboxes in
the window; done ones dimmed and struck through), headings as a symbol for
their level, list bullets as dots, `due:2026-10-03` as 📅 3 Oct (red
once it's past, yellow on the day and in the three days before), and
`remind:2026-10-06 18:00` as ⏰ 6 Oct 18:00. Code blocks keep their
markup, and the agenda leaves out todos in them. The file
stays plain Markdown: while you type on a line (insert mode), it shows as
written; in the vscode style, markup shows once the cursor is inside it. Click a
box to tick it, or press `enter` on it, and a heading's symbol folds its
section.

The symbols, rules of your own and how they all look are set from your
config:

```luau
local notes = require("@notes")

-- other symbols, e.g. from a Nerd Font
notes.symbols({ todo = "", done = "", bullet = "-" })

-- tags in their own colour, and !! shown as a flame
notes.rule({ pattern = "#[%w_-]+", style = "notes.tag" })
notes.rule({ pattern = "!!", show = "🔥", style = "notes.urgent" })

-- how a style looks is the theme's, like everything else
require("@greed").theme.set({ ["notes.tag"] = { fg = "magenta" } })
```

A rule's `pattern` is a Luau pattern; with `show` the match is replaced by
that text, and with `action` (a command name) clicking it or pressing
`enter` on it runs the command. The styles notes use are `notes.todo`,
`notes.done`, `notes.done.box`, `notes.heading`, `notes.bullet`,
`notes.due`, `notes.due.soon`, `notes.due.today`, `notes.overdue` and
`notes.remind`.

Agents can read and write your notes and todos too; see
[Agents](agents.md).

## Terminals

`:terminal` opens your shell in the project's folder, and `:terminal
COMMAND` runs a program instead, e.g. `:terminal cargo test`. Every key
goes to the program, including ones the editor would otherwise take, like
`ctrl-q`.

| Keys | |
|---|---|
| `space t` | Switch to a terminal, or open a new one |
| `space T` (in a file) | Send the selection, or the cursor's line, to the terminal you used last and run it: for a REPL or a shell beside your code |
| `ctrl-\`, `esc esc` | Stop typing into the program, to move around its output; one `esc` still goes to the program |
| `ctrl-space` | The same, then open the leader: `ctrl-space f` finds a file from inside a terminal |
| `alt-p` and the other `alt` pane keys | Work as in any pane: `alt-p x` closes the terminal's pane |
| `f1` | The keys that work while typing into it |
| `i`, `a`, `enter` | Type into it again |
| `p` | Paste the latest copy into the program |
| `g x`, `ctrl-click` | Open the link under the cursor (or the mouse), or the file a path there names, at its line |
| `[ p` `] p` | The command before or after the cursor, where your shell marks them (below) |
| `g o` | Select the output of the command at the cursor, to copy or search it |
| `] e` `[ e` | The next or previous file and line the output names, like a compiler's error at `src/main.rs:12:5`; `g x` opens it |
| `space d` | Pick from every file and line the output names, with what it says there, to open one |
| `:terminal-close` | End the program and close the terminal |

Out of the terminal, its output is text like any other: select it, search
it, copy it. Lines that scroll off the top stay above the screen, up to
`terminal-scrollback` lines (10000). When the program ends well its
terminal closes; when it fails, the output stays with how it ended, so you
can read what went wrong. A terminal keeps running while you look at other
files, and while you're detached. `:set terminal-shell "fish -l"` changes
what new terminals run. A terminal is called by what it runs and the
folder its shell is in, like `nu ~/src` or `cargo test ~/src`: on a
floating terminal's border, in the dock, the tab line and the status line.

Programs that ask for the kitty keyboard protocol (Helix, Neovim, fish,
recent shells) get it, so they can tell `tab` from `ctrl-i` or `enter` from
`shift-enter`. For those keys to reach Greed in the first place your own
terminal needs the protocol too (kitty, WezTerm, foot, Ghostty, Alacritty
and iTerm2 have it); Greed asks for it when it starts. `GREED_KEYS=legacy`
turns that off.

Links programs print (as `ls --hyperlink` and `gcc` do) are underlined, and
URLs written in the output open too. They open with `xdg-open` (`open` on
macOS), or whatever `:set link-opener firefox` names.

### Tasks

`space o t` picks a task to run: a command you run again and again, like
building or testing. It runs in a terminal below the file, which stays
open when it's done so you can read it, and running it again replaces the
last run. `] e` and `space d` in its output go to the files and lines it
names, like a compiler's errors. The last task you ran comes first, so
`space o t enter` runs it again; `:task test` runs one by name.

Greed finds tasks in the project: Cargo's `build`, `test`, `run` and
`clippy`, a `package.json`'s scripts, and a `Makefile`'s targets. Add your
own in `init.luau`; they win over found ones with the same name:

```luau
local terminal = require("@terminal")
terminal.tasks.lint = { command = "ruff check ." }
terminal.tasks.serve = { command = { "python", "-m", "http.server" }, cwd = "~/site" }
```

### Commands your shell marks

A shell can mark where each prompt, command and its output start, and how
the command ended. Greed then knows the commands in a terminal: `[ p` and
`] p` go between them, `g o` selects one's output, and a command that
failed shows its exit code at the end of its line.

fish 4 marks them on its own. For zsh, add this to `~/.zshrc`:

```zsh
_greed_precmd() { local code=$?; print -n "\e]133;D;$code\a\e]133;A\a" }
_greed_preexec() { print -n "\e]133;C\a" }
precmd_functions+=(_greed_precmd)
preexec_functions+=(_greed_preexec)
PS1="$PS1%{\e]133;B\a%}"
```

and for bash, to `~/.bashrc`:

```bash
PROMPT_COMMAND='printf "\e]133;D;%s\a\e]133;A\a" "$?"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS1="$PS1\[\e]133;B\a\]"
PS0='\e]133;C\a'
```

These are the same marks kitty, WezTerm, Ghostty and iTerm2 read, so they
work there too.

### The folder your shell is in

A shell can also say which folder it's in. Then a terminal you open from
a terminal starts in the same folder, and `g x` (or `ctrl-click`) on a path
in the output, like `src/main.rs:12:5` from a compiler, opens that file at
that line, finding it from that folder. Without it, paths are found from
the project's folder.

For fish, add this to `~/.config/fish/config.fish`:

```fish
function __greed_folder --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__greed_folder
```

For zsh:

```zsh
_greed_folder() { print -n "\e]7;file://$HOST$PWD\a" }
chpwd_functions+=(_greed_folder)
_greed_folder
```

and for bash, in `PROMPT_COMMAND`:

```bash
PROMPT_COMMAND='printf "\e]7;file://%s%s\a" "$HOSTNAME" "$PWD"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

## Shells

`:shell` opens a shell in a buffer, and `space o s` switches to one: type a
command at the prompt at the bottom and `enter` runs it. Each command
becomes a block above the prompt, its command, what it printed and how it
ended, which stays to search, fold, copy, run again and send to the next
command or to a buffer (`$3 | sort`, `cargo test > buf:tests`). Agents run
their commands there too. `space o w` lists what's running in every shell:
`enter` opens one in a float, `ctrl-o` goes to it and `ctrl-x` stops it.
Programs a shell runs that want an editor, like `git commit`, open the
file in Greed (`$EDITOR` is `greed edit --wait` there; `:set shell-editor
false` turns that off). [The shell](shell.md) has the rest: keys,
builtins, which shell runs a line, terminals, and limits.

## Panes and tabs

Split the screen between files and terminals, the way a terminal
multiplexer does, and keep tabs of layouts. Everything stays running in the
session, so after `:detach` and `greed attach` (or over `greed ssh`) the
panes, tabs and terminals are where you left them.

[![The file tree, a file and a terminal side by side, then a floating terminal over them](https://github.com/johnae/greed/releases/download/media/panes.png)](https://github.com/johnae/greed/releases/download/media/panes.mp4)

| Keys | |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | Move to the pane or panel (the file tree, an agent) on that side; from a pane at the left or right edge, on to the tab before or after, stopping at the first and last. In a zoomed tab it shows every pane again |
| `alt-n` | A terminal in a new pane, or a floating one while floating views are shown |
| `alt-f` | Hide the tab's floating views or show them again; with none, open a floating terminal |
| `alt-F` | This file in a new floating view |
| `alt-w` | Lay the tab's floats out with the next [float layout](#float-layouts) |
| `alt-{` `alt-}` | Bring the floating view before or after to the front |
| `alt-W` | Pick a floating view from the dock |
| `alt-=` `alt--` | More room for the pane (or floating view), or less |
| `alt-<` `alt->`, `alt-1`... | The tab before or after (round the ends), or tab N. `alt-[` and `alt-]` do the same in terminals with the kitty keyboard protocol; in others they start an escape code, so they can't be keys |
| `alt-p`, `alt-t` | The pane and tab modes, for everything else |
| `alt-r` | The resize mode: `h j k l` make the pane, panel or floating view bigger toward that side, `H J K L` smaller from it (at the screen's edge, the other edge moves), the arrows move a floating view |
| `ctrl-w v`, `ctrl-w s`, `ctrl-w q` | Split and close, as in Vim and Helix; `ctrl-w H J K L` swap with the pane on that side, `ctrl-w f` the file under the cursor in a split, `ctrl-w n s` an empty one |

The `alt` keys work everywhere, including inside terminals. Moving to a
terminal pane types into it; moving to a file goes back to normal mode.
Entering the pane or tab mode shows its most used keys at the bottom, as
many as fit; `f1` there lists them all. Keys in these modes that open
something (a terminal, a new tab, a prompt to name the tab, a picker of
layouts) leave the mode, so what they open goes back to where you were.
All the keys, and how to change them, are in
[Keys](keys.md#panes-tabs-and-terminals).

On a Mac, `alt` is Option, which also types characters of its own: `π`,
or `[` and `{` on a Swedish keyboard. In the window, Option with a key is
the `alt` key where that's bound, and types its character otherwise; plain
characters like `[ ] { } | @ $ \` are always typed, since a keyboard puts
them there to type them. With Shift, letters work as `alt` keys (`alt-F`),
other keys type their character. In a terminal, the terminal decides
(iTerm2, kitty, Ghostty and others can treat Option as Alt). Command with
a key is for the Mac and the menus (⌘V pastes, ⌘Q quits); the editor
leaves it alone. A keyboard in Windows layout on a Mac may send Command
from the key labelled Alt: switch it to its Windows mode, or swap the two
in System Settings > Keyboard > Modifier Keys.

To act on a pane without moving to it first, `alt-p g` puts a number over
each pane; type one to go there, and you're still in the pane mode, so
`alt-p g 3 f` zooms the third pane and `alt-p g 3 x` closes it; `esc`
leaves the pane mode. `ctrl-w g` and `space w g` label them too. While a
pane is zoomed the status line says "zoomed".

Floating views belong to the tab they opened in: switching tabs hides them
and closing the tab closes them. As in zellij, `alt-f` hides all of the
tab's floats and shows them again where they were (terminals keep
running), and opens a floating terminal when there are none. While floats
are shown, `alt-n` opens another floating terminal rather than a pane.
`alt-F` opens the file you're in as a floating view (`:float-file PATH`
for another), and `alt-p e` takes the pane or panel you're in out to float
over the tab, or puts a floating view back in as a pane. Floating the tab's
last pane leaves that pane showing another open file. Drag a float by its top
border to move it or by an edge to resize it, or use the resize mode
(`alt-r`). How the floats are laid out is up to the tab's
[float layout](#float-layouts).

To move what a pane shows somewhere else, `alt-p b` takes it to a new tab,
`alt-p t` to a tab you pick (or a new one), and `alt-p P` into a panel on
the right; its cursor goes with it and a terminal keeps running. They work
on a floating view too, and `t` and `b` on a panel. `:pane-to-new-tab`,
`:pane-to-tab` and `:pane-to-panel` do the same.

To put a new pane somewhere particular, `alt-p p` shows a frame where it
would go, on the right of the pane you're in. `h j k l` move the frame to
either side of any pane, or along a whole edge of the tab; `enter` opens a
pane there showing this file, `t` a terminal, and `esc` leaves things as
they were.

### Layouts

Each tab has a layout that arranges its panes as they open and close:

- `manual`: panes go where you split them. The default.
- `main-stack`: one main pane, the rest stacked beside it. A new pane takes
  the main place and the old main joins the stack.
- `columns`: all side by side.
- `spiral`: each pane takes half of what's left, winding inward.

`alt-space` goes to the next layout and `alt-p y` picks one; either says
which at the bottom, and the status line shows it while it isn't `manual`. A
tab's panes keep an order, and that's what you change:
`alt-m` swaps the pane into main, `alt-p o` moves them all one place
along, and `alt-p [` and `]` give main less room or more. Resizing a pane
by hand switches the tab to `manual`, keeping the shape it had.

`:layout-save NAME` saves the tab as it is: its panes, their sizes, and what
each shows, a file (relative to the project) or a terminal and what it runs.
It goes in the project, in `.greed/layouts/`, so it can be shared with the
rest of the repository; `:layout-save-mine NAME` keeps it in your config,
for any project. `:layout-open` picks one and opens it as a new tab. A
project can open one by itself from its `.greed/init.luau`:

```luau
require("@panes").saved.open("dev", { here = true })
```

`:set pane-layout main-stack` sets the layout new tabs start with. A layout
is a Luau function from the panes, in order, to how they're arranged, so
you can write your own:

```luau
-- every pane in a row of its own, one above another
require("@panes").layouts.define("rows", function(panes)
	return if #panes == 1 then panes[1] else { split = "column", children = panes }
end)
```

### Float layouts

With several floats open (agent sessions, terminals), the tab's float
layout says where they go and which of them show. `alt-w` goes to the next
one:

- `free`: they stay where you put them. The default. Coming back to `free`
  from another layout puts each float back where it was.
- `one`: one at a time, like tabs. Every float takes the same place at the
  same size and only the one in front shows; `alt-}` and `alt-{` bring the
  next one or the one before to the front, round the ends, without
  anything moving. The others keep running out of sight. Moving or
  resizing the one in front moves them all.
- `tiled`: side by side in a grid over the panes, laid out again as floats
  open and close and as the window changes size.
- `cascade`: overlapping, each a step down and right of the one before, so
  every title shows.

In `one` the float in front says where it is on its border:
`‹ 2/5 ›` at the right of the top, with the names of the floats either
side when it's wide (`‹ nu ~/src · 2/5 · claude ›`; of two, the other on
its side: `‹ 1/2 · claude ›`), and a dot for each
float along the bottom, the one in front filled. Click `‹` or a name before
it for the float before, `›` or a name after it for the next, or a dot
for that float (`:float-go N` does the same). A dock along the bottom
of the tab lists them all by number and name; click a name to bring that
float to the front, or press `alt-W` and then its number (or move with the
arrows and press `enter`). `:float-dock` shows or hides the dock in any
layout.

A float that needs you gets a colored dot, in its place along the border
and in the dock: an agent session waiting for your answer, or a terminal
whose command finished while it was hidden (until you look at it).

`alt-p O`, `T` and `C` pick `one`, `tiled` and `cascade`
directly, `alt-p Y` picks from a list (`:float-layout-pick`), and
`:set float-layout one` sets the layout new tabs start with.

A layout of your own is a function from the tab's floats to where each one
goes, its border included, and whether it shows:

```luau
require("@panes").floats.define("left-half", function(a)
	local places = {}
	for i in a.floats do
		local box = { x = a.room.x, y = a.room.y, width = a.room.width // 2, height = a.room.height }
		places[i] = { box = box, hidden = i ~= a.current }
	end
	return places
end)
```

`a.floats` are the tab's floats in the order they opened, `a.current` the
one in front, `a.room` the room the panes take and `a.boxes` where each
float is now. Plugins that show things in floats use
`require("@panes").floats.show(buffer)`, which opens the buffer in a float
of the tab (or finds the one it has) and brings it to the front,
`floats.focus(view)` for a float they have, and
`core.floats.attention(buffer, true)` to give it the dot.

## Clipboard

What you copy goes on your system clipboard too, through your terminal
(OSC 52), so it works over `greed ssh` and in tmux with `set-clipboard on`.
Most terminals allow it; some ask first or need it turned on (iTerm2:
"Applications in terminal may access clipboard"). `GREED_CLIPBOARD=off`
keeps copies inside Greed. A program in a Greed terminal that copies the same
way puts the text on Greed's clipboard, so `p` pastes it.

## Mouse

A click puts the cursor where you click and focuses that pane, dragging
selects, and the wheel scrolls whatever's under it. A double click selects
the word, a triple click the line, `shift`-click extends the selection to
where you click and `alt`-click adds a cursor there. Clicking a tab in the
tab line shows it. Drag a floating view by its top border (where the title
is) to move it, or by another edge or a corner to resize it. Drag the line
between two panes, or beside a panel, to give one more room.

Clicking a button (a proposal's accept and reject, a todo's box) presses
it. So does `enter` in normal mode with the cursor on it; where several
buttons share a spot, `enter` lists them to pick from.

In a terminal, a program that asks for the mouse (vim, htop, less with
`--mouse`) gets it. Otherwise the wheel scrolls back through the output,
which stops typing into the program, and scrolling back down to the bottom
types into it again; in a full screen program the wheel sends arrow keys. A
click types into the program, and a drag selects output to copy with `y`.

Most terminals still select text their own way while you hold shift.
`GREED_MOUSE=off` leaves the mouse to your terminal.

## Images

Greed shows images in terminals that speak the kitty graphics protocol:
kitty, Ghostty, WezTerm and Konsole. It finds out from the variables those
terminals set; `GREED_IMAGES=kitty` turns images on in another that speaks
the protocol, and `GREED_IMAGES=none` turns them off. Elsewhere, the text
under an image shows instead.

Programs in Greed's terminals can show images too, with the same kitty
protocol or iTerm2's: `kitten icat picture.png`, `imgcat`, chafa's and
yazi's previews. They scroll with the output, and text written over them
takes their place, as in any terminal.

Bigger text, like a heading a plugin scales up, is drawn big in the window
and in kitty, which can size text. Other terminals show it at the normal
size on the rows it takes. `GREED_TEXT_SIZING=on` or `off` decides it for
another terminal that can size text, or turns it off in kitty.

### Image files

Opening a PNG, JPEG or GIF shows the image, as wide as the pane at most,
under a line with its name, its size in pixels and the zoom. `+` and `-`
draw it bigger and smaller, `=` fits it to the pane again and `0` draws it
at its own size. It shows in the window and in terminals that show images.

### PDFs

Opening a PDF shows its first page, as wide as the pane. `]` and `[` go to
the next and previous page (with a count, that many), `+` and `-` draw it
bigger and smaller, and `=` as wide as the pane again. `t` switches to the
text of every page, which reads in any terminal and searches with `/`; `t`
again shows the page the cursor is on. Other files that aren't text open
read-only, so saving can't change them.

## The command line

`:` (or `alt-x` in the vscode style) runs any command by name, with completion.
`space ?` lists every command, `space h c` describes one and `space h k`
tells you what a key does. `space h h` describes anything the editor is
made of (commands, options with their values, events and who listens to
them, the plugin API, plugins, modes and editing styles), and `enter` in
the help window goes to where it's defined. `space h i` inspects what's
under the cursor (a buffer, a shell block or a row of its table, a
terminal, a file), or with nothing there the editor itself: its state, the
objects it relates to (`enter` goes to one, `backspace` or `ctrl-o` comes
back, `ctrl-i` goes forward again), what was done to it, by you or an
agent, and what it can do (`enter` runs that); `history` on `space .` lists
what was done to anything. After a key like `space`, a hint at the bottom
right shows what can follow, with groups of keys named (`w  panes…`), and
`f1` shows the keys of the mode you're in, in every mode. A message on the
status line goes away with the next key.

`:lua CODE` runs a line of Luau with the whole plugin API, and `:= EXPR`
shows what an expression is (`:= #greed.buffers()`).

The short names Vim and Helix users type work too: `:w` `:wa` `:q` `:qa`
`:wq` `:wqa` `:x` `:e` `:b` `:bn` `:bp` `:bc` `:ls` `:sp` `:vs` `:only`
`:tabnew` `:noh` `:rl` `:rla` `:set` `:toggle`, `:colo` (`:colorscheme`)
for `:theme`, `:setf` for `:language`, Neovim's `:checkhealth` for
`:health`, and Helix's long ones like `:write-all` and `:buffer-close`.
Arguments go after a space (`:w notes.md`); only Vim's line commands and
`:b` take one right after the name (`:m0`, `:t$`, `:b#`). A command that refuses, like `:q` with unsaved changes, says
why in plain words; an error from a bug in a plugin also names the plugin,
and `:errors` has the details.

Vim's line commands work in every style. A range in front picks the lines
a command works on; without one, it's the lines the selection touches
(`:g` and `:v` take the whole file).

| Command | |
|---|---|
| `:42`, `:$` | Go to line 42, or the last line |
| `:s/regex/text/flags` | Replace on the lines: `g` every match on a line, `i` ignore case, `I` match case, `n` only count; `\1` and `&` put back what matched. Undo puts the cursor back on the first line changed |
| `:g/regex/command`, `:v/regex/command` | Run a command on each line that matches, or doesn't; with no command, select those lines |
| `:d` `:y` | Delete or copy the lines |
| `:m 0` `:t $` | Move or copy the lines below a line (`0` is the top) |
| `:norm keys` | Type the keys in normal mode on each line |
| `:j` `:>` `:<` | Join, indent or dedent the lines |
| `:sort` | Sort the lines (the whole file without a range): `:sort!` backwards, and `u` one of each, `i` ignoring case, `n` by the first number |
| `:%!sort` | Put the lines through a program, as the pipe key does with a selection |
| `:!cargo test` | Without a range, run it in this project's shell, where its output stays |
| `:e!` | Load the file again from disk (an undo takes it back) |

Ranges are line numbers, `.` (the cursor's line), `$` (the last),
`/regex/` (the next line matching), `'<` and `'>` (the selection's first
and last line) and `%` (every line), with `+n` or `-n` after any of them:
`:%s/old/new/g`, `:.,+3d`, `:/^fn/,$norm A;`. Patterns are regexes, as in
search. In Vim's style, `:` in visual mode starts with `'<,'>` and `3 :`
with `.,.+2`.

While you type `:s`, the lines on screen show what it will do: the
pattern's matches, then, once you start the replacement, each match struck
through with its replacement next to it. Nothing changes until you press
enter, and `esc` leaves the file as it was.
`:set substitute-preview false` turns it off.

## Configuration

Your config is `~/.config/greed/init.luau`, plain Luau with the full plugin
API. `:config-open` (or `:config`) opens it, making the folder if it isn't
there yet. Your own plugins go in `~/.config/greed/plugins/NAME/`. A plugin
that appears there, or whose files change, loads by itself, asking you
first if it wants something you haven't approved; `:plugin-reload NAME`
loads one again by hand. [Writing plugins](plugins.md) has more.

### Where Greed keeps things, and profiles

Greed keeps four folders: your config (`~/.config/greed`), data like saved
agent sessions (`~/.local/share/greed`), a cache (`~/.cache/greed`) and
state like the plugins you approved and kept secrets
(`~/.local/state/greed`). The `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
`XDG_CACHE_HOME` and `XDG_STATE_HOME` variables move them as usual.

A profile keeps everything in one folder of your choosing, with sessions
of its own that never meet your usual ones:

```bash
greed --profile ~/greed-work            # a setup of its own
greed --profile "$(mktemp -d)"           # Greed as on its first run
```

The profile holds `config`, `data`, `cache`, `state` and `run` (its
sessions' sockets). Each folder can also be set on its own with
`--config-dir`, `--data-dir`, `--cache-dir` and `--state-dir`, for scripts
that move only one. Each flag has a variable too (`GREED_PROFILE`,
`GREED_CONFIG_DIR`, `GREED_DATA_DIR`, `GREED_CACHE_DIR`, `GREED_STATE_DIR`):
a folder's own setting wins over the profile, which wins over the XDG
variables. Sessions' sockets go in `GREED_RUN_DIR` when it's set, which
helps when a profile's path is too long for a socket (they're limited to
about a hundred characters). Sessions, terminals, shells and agents Greed
starts get the same folders, so `greed ctl` inside one of its terminals
finds its session.
`HOME` stays yours, so git, kubectl and your keys work as usual.

Saving your config, in Greed or anywhere else, runs it again within a
second: what it registered (commands, keys, theme entries, event handlers)
is taken away and set up anew, and the status line says "config reloaded"
or what went wrong. Options it set keep their values until it sets them
again. `:config-reload` does the same by hand.

For `luau-lsp` to check your config and complete it, it has to know what
`require("@greed")`, `require("@theme")` and the other plugins are. Greed
writes a `.luaurc` that tells it, beside the config folder
(`~/.config/.luaurc`, since luau-lsp looks for an `init.luau`'s settings
in the folder above), and keeps it pointing at the Greed you run. It only
writes over a `.luaurc` it wrote itself: if you had one there or change
it, it's yours, and `:config-types` says so.

Config runs in layers, each after the one before, so later ones win:

1. The default plugins.
2. The config `greed ssh` brought from your machine, in a session on
   another one.
3. This machine's own config, `~/.config/greed`.
4. The project's own config, `.greed/init.luau` in the project, once you
   trust it.

A project's config is code from whoever wrote the repository, so it doesn't
run until you say so: opening a project that has one tells you, and
`:trust` runs it, now and whenever the project opens again. Trusted
projects are listed in `~/.cache/greed/trusted-projects`; take a line out
to stop trusting one.

```luau
local greed = require("@greed")

-- Keys
greed.keymap.bind({ layer = "leader" }, { W = "save-all" })

-- Options (`:set` changes them while running)
greed.option.set("flash-duration", 150)

-- The theme: change a few names, or all of them
greed.theme.set({
	["ui.selection"] = { bg = "#3b3f51" },
	["keyword"] = { fg = "magenta", bold = true },
})

-- A language
require("@languages").set("python", { servers = { { "pylsp" } } })

-- Turn off a default plugin
greed.plugin.unload("hints")
```

[Keys](keys.md) covers key names, modes and taking keys away.

### The status line

The status line shows the mode, the tab, the tab's layout when it isn't
`manual` and `zoomed` while one pane fills it, the file and whether a
macro is recording on the left. The file is the one you're in: a focused
panel or floating view (a floating terminal) counts, a picker or the
command line doesn't. Buffers without a file show by name, like
`terminal: nu ~/src`, or `untitled` for a new file. While you type a
command after `:` the mode says `COMMAND`, and in a prompt like search's
`PROMPT`. The file gets `[+]` while it has unsaved changes; undoing back
to what was saved takes it away. On the right it shows:

- the branch and the lines added, changed and removed in the file, like
  `main +3 ~1 -2` (with jj the nearest bookmark and the change you're on,
  like `main · nwpr`)
- todos due today, like `2 due today` (see [Reminders](#reminders))
- problems
- the language and the features on for the file, like `markdown · notes`
- the language server: its name, what it's working on
  (`rust-analyzer: indexing 40%`), or that it's starting, stopped or not
  installed
- the editing style, dim, like `helix`; click it to pick another
- anything unusual about the file, and only then: `CRLF` line breaks,
  `tabs` (or `spaces`) where its language indents the other way, or
  `read-only`
- how many selections there are, once there's more than one
- agents at work or waiting for you, like `◆ 1 working · 1 waiting for you`
- the cursor's line and column (the character the cursor is drawn on, at
  the end of a selection too), the machine and the session

Two options make it livelier, both off unless you turn them on:

```luau
local option = require("@greed").option
-- The mode, tab, machine and session as pills in their theme colors, with
-- rounded ends (they need a Nerd Font; statusline-caps "none" makes them square)
option.set("statusline-pills", true)
-- A wave of light through the letters of the tab or the file when you go
-- to another, a glow from the middle of the mode when it changes, and in
-- an agent's pane, spinning tools and a status that moves while it works
option.set("effects", true)
```

The wave's letters glow towards the theme's `ui.glow` color: brighter text
in a dark theme, the accent in a light one. Effects need a theme with
`#rrggbb` colors, so the default 16-color theme has none.

### Highlights that show what changed

Some highlights tell you something, so they're on unless you turn them
off. Each has an option of its own:

- `effects-changes`: text someone other than you changes (an agent, a
  formatter, a language server's rename or fix, a plugin, the file changing
  on disk) gets a faint background in the views showing it for a second,
  then fades out over a second and a half. What you type, paste, undo or pick from a completion
  menu doesn't.
- `effects-jumps`: the line a jump lands on lights up for a moment: a
  search hit, going to a definition, back and forward through the jumplist
  (`ctrl-o`, `ctrl-i`), a picker opening a file at a line, and any move of
  more than a screen. Ordinary moves don't.
- `effects-dim`, off by default: the panes you're not in are dimmed, their
  text blended towards the background in the window, and in a terminal
  drawn with its dim attribute.

```luau
local option = require("@greed").option
option.set("effects-changes", false)
option.set("effects-dim", true)
```

The colors are the theme's `ui.changed` and `ui.jumped` backgrounds. With
`#rrggbb` colors they fade in a few steps, in the terminal too; with the
terminal's 16 colors changed text is underlined for a moment and the
line a jump lands on gets a gray background, then both go. In a
repository, the gutter's `+`, `~` and `-` signs also mark the lines that
changed, without relying on color, and the cursor is on the line a jump
lands on.

Add pieces of your own, or take some away:

```luau
local statusline = require("@statusline")
statusline.add("right", "clock", function()
	return os.date("%H:%M")
end)
-- A pill in a theme style
statusline.add("left", "env", function()
	return { text = "staging", style = "ui.statusline.tab" }
end)
statusline.remove("host")
```

A piece gets the main view, its buffer, the mode and the message, and
returns text, a pill (`{ text, style }`), a list of pills shown joined, or
nil to show nothing. The pills' colors are the theme's
`ui.statusline.mode`, `.tab`, `.tab.number`, `.host` and `.session`;
`.dim` is the editing style's.

A piece is drawn with every frame, so it has to be quick and can't run
programs. For anything that takes time, like a repository's state in a big
monorepo, add an async piece: its `refresh` runs in the background and can
run programs, and the status line shows what it last found, never waiting
for it.

```luau
statusline.add_async("right", "change", {
	refresh = function()
		local done = require("@greed").process.run({
			"jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short()",
		})
		return done and done.code == 0 and done.stdout or nil
	end,
	every = 5000, -- milliseconds
	on = { "buffer.saved" }, -- and whenever these happen
})
```

### Themes

`:theme` lists the themes and tries each one as you move through the list.
`enter` keeps it, `esc` goes back to the one you had, and `:theme nord`
switches straight away. Tab through the matches after `:theme ` tries each
one the same way. The theme you pick is remembered for next time, unless
your `init.luau` sets one with `theme.use`, which runs later and wins.

Greed comes with `default` (your terminal's 16 colors, so it follows your
terminal's palette), `nord`, `nord-light`, `dracula`, `catppuccin-mocha`,
`catppuccin-macchiato`, `catppuccin-frappe`, `catppuccin-latte`, `gruvbox`,
`gruvbox-light`, `onedark`, `tokyonight`, `tokyonight-storm`,
`solarized-dark`, `solarized-light`, `rose-pine`, `rose-pine-dawn`,
`kanagawa`, `everforest` and `monokai`.

Themes are Luau. Set one, or make your own, in `init.luau`:

```luau
local theme = require("@theme")
theme.use("nord")

-- A built-in theme with changes
theme.define("my-nord", {
	inherits = "nord",
	styles = { comment = { fg = "#7b88a1", italic = false } },
})

-- A theme from a palette: backgrounds, text and hues, and optionally
-- fg_alt, accent, and colors for syntax: keyword, func, string, type,
-- constant and operator
theme.define("mine", {
	palette = {
		bg = "#101418", bg_alt = "#181e24", bg_high = "#232b33", selection = "#2c3640",
		fg = "#d0d6dc", comment = "#5c6773", gutter = "#3a444e",
		red = "#e06c75", orange = "#d19a66", yellow = "#e5c07b", green = "#98c379",
		cyan = "#56b6c2", blue = "#61afef", purple = "#c678dd",
		keyword = "#c678dd",
	},
})
```

`greed.theme.set` changes single names on top of whichever theme is in use,
and those changes stay when you switch themes. Each changes only the fields
it gives: `greed.theme.set({ comment = { italic = false } })` keeps the
theme's comment color. A theme's own `styles` work the same way on what it
inherits. Names fall back to their parent, so `keyword.control` uses
`keyword` unless it has its own entry; [Highlighting](highlighting.md) lists
them.

With several terminals attached to a session, each shows the others'
cursors and selections in their own color: client color N (1 to 6) uses
`ui.cursor.peer.N` and `ui.selection.peer.N`, which fall back to
`ui.cursor` and `ui.selection`. The built-in themes give each a color of
their palette, with selections underlined.

One theme serves the terminal and the window. Where they should differ, an
entry's `tui` and `gui` parts change it for one of them, like
`["ui.float"] = { bg = "black", gui = { bg = "#25282c", rounded = true } }`.
`rounded`, `shadow`, `badge`, `checkbox` and `font` are for the window
only: the first two make floats boxes with rounded corners and a soft
shadow, `badge` draws a style's background as a small box with rounded
corners, like a key cap (motion hints and buttons use it), `checkbox =
"empty"` or `"checked"` draws a checkbox over the text (todo boxes use it),
`"choice"` or `"chosen"` a round button (Markdown choices use it),
and `font = "prose"` sets text in the proportional font.

`#rrggbb` colors go out as they are when the terminal says it shows 24-bit
color (`COLORTERM=truecolor`, as most do), and as the nearest of 256 colors
when it doesn't, like tmux without its `RGB` feature. `GREED_COLORS=truecolor`
or `GREED_COLORS=256` decides for a terminal that says the wrong thing.

### Highlighting and syntax queries

Greed has grammars built in for Rust, Nix, Bash, Python, Go, JavaScript,
TypeScript, C, Luau, JSON, TOML, YAML and Markdown. For C++, C#, Java,
Ruby, Scala, Haskell, OCaml, Julia, HTML and CSS it downloads the grammar
the first time you open a file in that language, checks it against a
checksum Greed knows, and keeps it in `~/.cache/greed/grammars`.
`:health` shows which languages are built in, which download, and which
have no grammar. `:grammar-fetch ruby` downloads one ahead of time, say
before going offline, and `greed.option.set("grammar-download", false)`
turns downloading off.

What gets highlighted, and what counts as a function for `m i f`, comes
from tree-sitter queries: files named `queries/LANGUAGE/KIND.scm`, where
KIND is `highlights`, `injections` (languages inside others, like the code
blocks in Markdown, which are highlighted in their own language),
`textobjects`, `folds` (the blocks `z a` folds, captured as `@fold`) or
`indents` (nodes whose lines go a level in, `@indent`, and closing tokens
that line up with their block's first line, `@outdent`).
Greed reads them from every plugin and from `~/.config/greed/queries`, so a
file there replaces Greed's own. To add to it instead, start the file with
`; extends`:

```scheme
; extends
; ~/.config/greed/queries/rust/highlights.scm: TODO in comments stands out
((line_comment) @comment.todo (#match? @comment.todo "TODO"))
```

[Highlighting](highlighting.md) lists the names highlights queries use
and the theme styles.

A query with a mistake in it says so when Greed starts, and the one before
it stays in use. `require("@languages").load_queries()` reads the files
again after you change them.

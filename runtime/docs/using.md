# Using Greed

## Starting and sessions

`greed FILE` opens a file; one that isn't there yet opens empty, and `:w`
writes it there. The editor runs as a session in the background,
and what you see is a client attached to it: the terminal, a window
(`greed --gui`), or several at once, here or over `greed ssh`. Closing a
client (or `:detach`) leaves the session as it was: open files, undo
history, language servers.

Each project gets its own session, named after its folder. `greed` anywhere
in a project attaches to that session (opening the file you named), or
starts it. A slow plugin or a crash in one project's session leaves the
others alone. How sessions keep track of each other, here and on other
machines, is in [Sessions, machines and the hub](sessions.md).

| Command | What it does |
|---|---|
| `greed [FILE or FOLDER]` | Attach to the project's session, or start it |
| `greed --session NAME [PATH]` | Attach to or start a session with this name, e.g. a second one for a project |
| `greed --new [PATH]` | Start another session for the project, beside the one running, with this greed: for trying a newer build |
| `:detach` | Leave the session running |
| `greed attach [NAME]` | Attach to a session; the only one if there's one |
| `greed ls` | List running sessions, their projects and how their agents are doing (`◆ 1 waiting for you`), marking those running another build than this greed |
| `greed serve [PATH]` | Run a project's session with no terminal |
| `:q` | Close the pane, as Vim closes a window, when the tab has others; the tab, when it's the last pane and there are other tabs. Otherwise close the shown project and leave; on the last one, end the session unless something is running in it (see below). In a panel or a float (an agent's transcript, help) it closes only that |
| `:quit-session`, `:qa` | End the session, whatever runs in it. With unsaved files it lists them and stops; `:wa` saves them, `:wqa` saves them and ends it, `:qa!` ends it anyway |
| `greed edit [--wait] FILE...` | Open files in the running editor; with `--wait`, return once each is closed with `:q` or `:wq` (`:cq` fails it), as `$EDITOR` for `git commit`. Greed's own shells set this up already |
| `greed ctl quit [--force] [NAME]` | End a session from a shell, unless it has unsaved changes (`--force` ends it anyway) |

A session keeps running the greed it started with. `greed --version` names
the build (`greed 0.2.0 (build b5432b407145)`, a hash of what it was built
from). Attaching to a session of another build, as after rebuilding greed
while it ran, says so on the status line: `greed --new` starts a session of
your build beside it, and `greed ctl quit NAME` ends the old one. `greed
ssh` puts your build on the other machine when it runs the same system, and
keeps the last few builds there.

A session of another version of Greed, as after upgrading while it ran,
can't be shown: the two speak different protocols. Greed shows a page with
the session's unsaved files and what's running, in the terminal, the window
or over `greed ssh`, and offers to:

- end it and start your version in its place,
- open it with the version it runs, to save your work first (when that
  greed is still on this machine),
- start your version beside it.

A number picks, `esc` leaves it as it is. From a shell, `greed ctl state
NAME` prints what's unsaved and running in a session of any version, and
`greed ctl quit NAME` ends it; the next `greed` then starts a new one.

Several terminals can show one session: run `greed` or `greed attach` in
another terminal, or `greed ssh` from another machine. They share buffers
and undo history; each has its own cursors, focus and mode, and `:detach`
lets only that one go. A terminal coming back from the same machine gets
its cursors, focus and mode back; a new one starts where the one used last
is. Copies go to the clipboard of the terminal that copied, desktop
notifications to the one used last.

Attached terminals follow each other: same project, tab and panes, each
with its own focus and pane zoom. `:client-independent` lays one out on its
own, `:client-follow` has it follow again. Pickers, prompts and the command
line show only on the terminal that opened them, and a program in a
terminal pane is sized for the client that last typed into it. [Several
clients](clients.md) has the details.

`greed commands` lists every command line command, including the ones
plugins add (`greed ls`, `greed new` and `greed bring` are plugins too).

Switching to another session (`space P`, `:session`) moves your terminal
there and leaves the session you were in running. Over `greed ssh` it
reconnects through a new ssh connection, which is close to instant with
ssh connection sharing (`ControlMaster`).

In one of Greed's own terminals, `greed FILE` opens the file in that session
and returns, rather than starting an editor inside the editor, and
`greed ctl` talks to that session. Programs there can tell from
`$GREED_TERMINAL`, which names the session; `$GREED_TERMINAL_ID` says which
terminal and `$GREED_BIN` which greed runs the session.

If a session can't start in the background, `GREED_NO_SESSION=1 greed FILE`
runs the editor directly in the terminal.

A session remembers its projects, their open files and cursors, and the
tabs of the project you were in: panes, what each showed, and their
terminals, which run what they ran again (one that ran something risky,
like `rm -rf` or `kubectl delete`, comes back as a plain shell). When it
ends without being quit, as in a crash, a reboot or a logout, the next
start opens all that again. A session you quit (`:quit-session`, `:qa`)
starts clean next time. Ending one to start it again with a newer greed,
from the page that asks about the other version, restores it. This is
written when the session starts, quits, and opens, closes or saves a
file, in the cache folder (`~/.cache/greed/sessions`). Starting with a
file keeps that file shown.

| To | |
|---|---|
| Start one session fresh | `greed --fresh` (or `greed ssh HOST --fresh`); quit a running one first, or start another with `--new` |
| The same on a Mac | Hold Shift while Greed opens |
| Bring back a session you quit | `greed --restore`, as the next start after quitting it |
| Restore after quitting too, always | `greed.option.set("restore-after-quit", true)` |
| Turn restoring off | `greed.option.set("restore-session", false)` |

### Quitting or keeping a session

`:q` and `:wq` in a pane with others beside it close that pane, as Vim
closes a window; in a tab's last pane they close the tab while there are
others. The file stays open, so this never asks about unsaved changes.
`ctrl-q` in the vscode style asks to save, quit without saving or cancel,
as VS Code does.

`:q` on the last project ends the session, unless that would stop a
command in one of its terminals, a program like a task, or an agent at
work. Then it detaches and the session keeps going, so `greed` comes back
to it. A shell waiting at its prompt doesn't count. Over `greed ssh`, `:q`
keeps the session by default, since reattaching is quicker than starting
again over the network.

`:quit-session` (or `:qa`) ends it whatever runs in it. Unsaved files stop
it: it lists them, `:wa` saves them and `:qa!` ends the session anyway.
Terminals, shells, agents' panes and other scratch buffers never count as
unsaved.

Set what `:q` does, here and over `greed ssh`:

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

Started without a config (`~/.config/greed/init.luau`), Greed shows a setup
page that asks:

- how you like to edit, and which theme (both switch at once, to try them),
- whether your font has icons (in a terminal, which needs a Nerd Font; the
  window has them built in and doesn't ask),
- whether to add Greed's tools to the agents installed here (Claude Code,
  Codex, Gemini CLI),
- which language model Greed's agent and other features use (Anthropic,
  OpenAI, Berget, Mistral, Ollama on this machine, or none for now).

The page is a [questionnaire](#questionnaires) and works the same in every
editing style: `tab` and `shift-tab` move between choices, `enter`,
`space` or a click picks one or presses a button. Under the models, a
button sets the API key (kept in the system keyring) or signs you in; for
Ollama the page says whether it answers, and if not, to run `ollama serve`
and `ollama pull llama3.2`.

**Save** writes an `init.luau` from your answers and opens it, and points
the `fast` and `reasoning` roles at the provider you picked (`:models`
changes them later). Below your answers it lists more settings, commented
out: remove the `--` and save, and one applies at once. `space h o`
describes an option, and `:set NAME VALUE` tries one for the session.
Save never replaces an existing config; it shows what to add instead, and
`esc` closes that.

**Not now**, `esc`, `q` or closing the page writes nothing. Either way the
page doesn't come back by itself; `:setup` opens it again, or goes to it if
it's open.

`:tutor` teaches the keys of the style you picked, with lines to practise
on in each lesson (each says done once you get it right), then shows the
leader, finding files, panes, the shell and sessions. Picking another style
on the page switches the lessons too. Nothing on the page is saved;
`:tutor` gives a fresh one.

### In a window

`greed --gui [FILE]` shows the session in a window, drawn on the GPU. It's
the same session a terminal attaches to, and `greed ssh HOST --gui` shows a
session on another machine in a window here. Closing the window detaches,
as `:detach` does. Going to another session (`space P`, `:session`)
shows it in the same window, as a terminal would; `alt-w` in `space P`
opens one in another window instead.

`ctrl-shift-n` (`cmd-n` on macOS, or File, New Window) opens another
window on the same session, laid out on its own from what this one shows,
the way a terminal's new window starts where you are. `space P` in it
takes it to another project.

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

Dropping a file on the window pastes its path, as a terminal does, so a
screenshot dropped on a terminal pane running Claude Code hands it the
picture. With the session on another machine (`greed ssh`), the file is
copied there first, into the cache folder's `dropped`, and that path is
pasted; files over 50 MB stay behind with a message. In a terminal,
dropping a file pastes its path too; over `greed ssh` a paste of nothing
but paths to files on your machine sends the files along, so the session
gets paths it can read.

Copies in Greed go to the system clipboard, and what another program
copied becomes Greed's clipboard when the window gets focus, so `p` (or
`ctrl-v` in the vscode style) pastes it. `ctrl-shift-v` and `shift-insert`
(`cmd-v` on macOS) paste the system clipboard at the cursors in any mode,
as a terminal's paste does.

Lines copied whole (`y y` in the Vim style, `x y` in Helix's, `ctrl-c` with
nothing selected in the vscode style) paste above or below the line in all
three styles. Text copied in another program pastes at the cursor.

`ctrl-=` and `ctrl--` zoom in and out, `ctrl-0` puts the size back; each
window zooms on its own. Font and size go in your `init.luau`, and windows follow as
soon as they change:

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

Scrolling glides, whether you scroll or a streaming reply keeps the view at
its end. To jump instead:

```luau
greed.option.set("gui-smooth-scroll", false)
```

Buttons, fields and choices light up as the mouse goes over them. With an
input method (for Japanese, Chinese or Korean, say), what you're composing
shows underlined at the cursor until it's typed.

In the window, floats (pickers, prompts, hover info) have rounded corners
and a shadow (lighter on a light background) unless the theme turns them
off; terminals draw square box lines. The window draws the round ends of the
status line's pills itself, so they need no Powerline font. Square floats
without shadows, or rounded ones in the terminal too (`╭╮╰╯`, if its font
joins them well):

```luau
greed.theme.set({ ["ui.float"] = { gui = { rounded = false, shadow = false } } })
greed.theme.set({ ["ui.float"] = { tui = { rounded = true } } })
```

## Projects

A project is the nearest folder above a file that holds `.jj` or `.git`,
or the folder itself if none does. A session can hold several projects:
each has its own files, main view and panels (file tree, search results),
and the file picker, project search and tree work within the shown one.

| Keys | |
|---|---|
| `:project PATH` | Open the project `PATH` is in here, in this session, or switch to it |
| `space P` | Go to a project: one open here, another running session, a recent one, or one your sources find; each says what `enter` does with it. Type a folder path (`~/src/`) to list the folders in it, `tab` to go into one |
| `alt-o` in `space P` | Open the project here, in this session, beside what's open |
| `alt-enter` in `space P` | Open the project in a new session, even if one is running for it |
| `alt-w` in `space P` | In a window, open the project in another window and keep this one; in a terminal, go to it as `enter` does |
| `space C` or `:connect HOST` | Show a session on another machine here, as `greed ssh` does: pick from the hosts you connected to lately and those in `~/.ssh/config`, or type one |
| `:session NAME` or `:session PATH` | Go to a running session, or to the session for a project (starting it) |
| `space B` or `:session-back` | Go back to the session you were in before, on whichever machine; again to return |
| `:session-home` | Go back to this machine from another: the session here you were in last |
| `:project-close` | Close the shown project |
| `:q` | In the last pane of the last tab, close the shown project and leave; on the last project, end the session unless something runs in it |
| `:qa` | End the session and every project in it |

A project gets a session of its own by default. `enter` in `space P` goes
to a project open here, or to the session running for it, and starts a
session for a recent project or a folder you typed, like `greed FOLDER`
from a terminal. Each entry says which: `(open here)`, `(goes to session
greed)`, `(recent, starts a session)`. To work across projects in one
session, like a library and the app using it with one buffer list and one
grep, open the second one here with `alt-o` in `space P` or `:project
PATH`. Like every `space` key here, `space P` is on the leader: in the
vscode style, where space types, it's `ctrl-space P`.

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
another machine, starting one if none is running; `--new` starts another
beside it. Files, language servers, search and agents run on that machine;
only keys and screen updates cross the network. After `:detach` the session
keeps running, and `greed ssh HOST` comes back to it.

If the connection drops (the network goes, the laptop sleeps), `greed ssh`
says so and reconnects to the same session by itself, waiting a little
longer between tries (`ctrl-c` stops it). The two ends check in every few
seconds, so a quiet connection is noticed within about fifteen seconds, and
the session lets that client go then too.

From inside Greed, `space C` (`:connect`, or Connect to Host… in the
window's File menu) does the same without a terminal: pick from the hosts
you connected to lately and those in `~/.ssh/config`, and the window or
terminal you're in moves to that machine's session. `space B` goes back,
and again returns, so sessions on two machines are a key apart. On another
machine `space C` lists home first (`:session-home`): the session on your
own machine you were in last.

| Command | |
|---|---|
| `greed ssh HOST --terminal` | Show the session and open a terminal on that machine in a new tab; it runs in the session, so it survives a disconnect. `greed --terminal` does the same here |
| `greed ssh HOST --shell` | Show the project's greed shell, opening one if there's none (see [The shell](shell.md)); `greed --shell` here |

### What runs where

Everything in the session runs on the other machine, with its programs,
folders and variables: your config and plugins, files and saving, shells
and terminals, language servers, search and agents. The Greed in front of
you draws the screen and sends keys, mouse and clipboard, and needs nothing
of the project.

### Your config, both ways

Each `greed ssh` copies your `~/.config/greed` (`init.luau` and your
plugins) to the other machine first, into
`~/.cache/greed/config-from-<this machine>`, replacing the copy from last
time, and a session it starts runs that copy.

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

`greed bring HOST` lists the plugins in the other machine's own config and
data folders, and `greed bring HOST PLUGIN` copies one into your config's
`plugins` folder. A running Greed loads it at once, after asking you to
approve what it uses.

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

Greed doesn't have to be installed there. The first time you connect with
a version, `greed ssh` puts the same version in
`~/.local/share/greed/server` and uses it from then on: a copy of the greed
you run when it runs there, otherwise (NixOS, or an arm machine) that
version's static build from the releases, checked against the release's
checksums. A greed of the same version already on that machine's `PATH` is
used as it is. Where there's no greed on its `PATH`, a session puts its own at the end of
its programs' `PATH`, so `greed FILE` in its terminal opens the file there.
The programs that come beside `greed`, like `greed-mail` for `greed mail`,
go along with it, built for that machine too; a machine that got its greed
before they did gets them the next time you connect.

`GREED_REMOTE` sets the path of `greed` on the other machine, and nothing
is copied (the two ends check they speak the same protocol, and say so if
they don't); `GREED_REMOTE_BINARY` names a greed built for it to copy (like
`nix build .#static`'s, between releases). `GREED_SSH` sets the ssh
program to use. It's run as one program, so for options like a port use
`~/.ssh/config` or a small wrapper script.

### Your ssh agent

For a host your `~/.ssh/config` forwards the agent to (`ForwardAgent
yes`, as `ssh -G HOST` shows it), Greed forwards your ssh agent itself.
The session there has its own agent socket, which its shells and
terminals get as `SSH_AUTH_SOCK`; each request on it goes to the agent on
the machine you're attached from. The socket stays the same across
reconnects, so `git push` in a shell open for a week reaches your keys
after you come back, from this machine or another. With nobody attached, a
request fails at once. Greed turns ssh's own forwarding off for its
connection, so the session has one way to your keys.

The agent used is the one `SSH_AUTH_SOCK` names where you run `greed ssh`,
if it answers; otherwise (a shell can keep a stale one, say from a closed
terminal window) the `IdentityAgent` your ssh config names for the host.
When neither answers, the status line says so and why, instead of only
"agent refused operation" in the program that asked.

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

Greed has three editing styles: Helix's (select, then act), Vim's (act,
then where) and modeless, as in VS Code. Greed asks which the first time it
starts, `:style vim` switches at any time, and [Editing
styles](editing-styles.md) has each one's keys and how to make one your
own.

Keys typed while a command is still working (say, on a slow program) wait
for it, up to half a second, and then run in order. `esc` and `ctrl-c`
reach a working command at once, unless keys typed before them are still
waiting.

Long lines wrap after a space where they can, and wrapped rows start at
the line's indent (unless that would take more than half the view).

Messages show on the status line, one line each; a longer one, like an
error with its stack trace, ends in `…`. `:messages` shows the last ones
in full.

This page shows the Helix style, Greed's default: select text, then say
what to do with it. There is always a selection; a cursor is a selection
one character wide.

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

`:set line-numbers relative` numbers lines by distance from the cursor's
line, so the line marked 5 below is `5 j` away. `hybrid` also shows the
cursor's line's own number, and `absolute` goes back.

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
| `:snake-case` `:camel-case` `:pascal-case` `:kebab-case` `:title-case` `:sentence-case` | Change the selected words to that case, each line on its own: `fooBar` to `foo_bar`, `fooBar`, `FooBar`, `foo-bar`, `Foo Bar` or `Foo bar` |
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

Undo lasts across restarts: each time you save a file, its undo history
is kept in Greed's cache folder, and when you open the file again, as it
was saved, undo goes on past where it was opened. A file something else
changed in between starts afresh. Since undo keeps deleted text, files the
project ignores and files named like secrets (`.env*`, `*.pem`, `*.key`,
`id_*`) aren't kept; the rest are readable only by you, go after 30 days
without a save, and a history over 10 MB isn't kept. `:set undo-files
false` turns it off.

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
`enter` puts the closing one on its own line. A line holding only a closer
like `end`, `else` or `}` lines up with its block when you press `enter` on
it, and a closing bracket does as you type it at a line's start.

Languages without a grammar, and code that doesn't parse yet (a Ruby `def`
before its `end`), keep the line's indent, one level more after an opening
bracket (or a `:` in Python and YAML), going by the language's keywords
(`indent_after` and `outdent_before` in its entry).

Each language has its own indent, like two spaces in Nix or a tab in Go;
the `indent` option is for files in no language. Tabs show 4 columns wide;
a language's `tab_width` changes that for its files, and `:set tab-width 8`
for the rest:

```luau
require("@languages").set("nix", { indent = 4 })
require("@languages").set("go", { tab_width = 8 })
```

Brackets and quotes come in pairs as you type them in the helix and
vscode styles: `(` brings its `)` with the cursor between, typing `)` next
to one steps over it, and backspace between an empty pair deletes both. A
pair only opens before a space, a closer or the line's end, and a quote not
after a letter or digit, so `don't` stays as typed. In the vscode style, an
opener typed over a selection goes around it. Vim's style leaves them alone,
since `.` and macros replay what was typed. `:set auto-pairs on` (or `off`)
says otherwise for any style, and `style` goes back to the style's way.
Each language can have its own pairs; Rust's leave `'` out, for lifetimes:

```luau
require("@languages").set("lua", { pairs = { ["("] = ")", ["{"] = "}", ['"'] = '"' } })
```

A file gets its language from its name; `:language NAME` gives a buffer
another one (`:setf` too, as in Vim), and `:language` alone says which it
has. `:reindent-lines` indents the selected lines again, for code pasted in
at the wrong indent.

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
| `] m` `[ m` | The next or previous item where a buffer is made of them: a message in a chat room or a mail thread, a row of the mail list; a count goes that many |
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
cursor's line, from the language's grammar. Without a grammar, it's the
lines indented under the nearest line indented less. In Markdown it's the
innermost fenced code block, list item with lines under it (a todo and its
subtasks) or section under a heading.

Vim's style folds with `tab`, `z a`, `z o`, `z R` and `z c` (no `z C` or
`shift-tab`), plus `z M` to fold every outermost block, `z f` + a motion to
fold those lines, `z j` `z k` for the next or previous fold, and `z d` `z E`
to unfold.

`:style vim` and `:style vscode` switch styles; [Editing
styles](editing-styles.md) explains each.

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
| `space L` | List the lines of this buffer that match, as you type (`search-buffer`) |

Patterns are regexes. The `search-case` option sets how searches mind
case: `"smart"` (the default) ignores case unless what you type has a
capital letter; `"ignore"` and `"match"` always do one or the other. It
covers searching a file, the project search, `:g` and the pickers' fuzzy
matching. A few searches have their own option and default; `"default"`
hands them back to `search-case`:

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

In the project search, `enter` opens a match and `ctrl-e` puts the results
in a panel a third of the screen wide: a multibuffer, each matching line
under its file's name and beside its line number. Edit those lines with
the usual keys (`s` to select the matches, then `c` to change them all)
and the files change as you type; `:w` saves them, `enter` goes to the
line and `q` closes the panel. A file that changed on disk since the
search is left alone and reported. `:grep PATTERN` fills the panel
directly.

`space L` is the same search in the buffer you're in: every matching line
in a list with a preview, where `/` only jumps from match to match. It
searches the text as it is, unsaved changes included, and works in
buffers without a file too. `ctrl-e` puts a file's matches in the panel,
the same way.

### Your notes, mail and chat at once

`space n s` (`:search-everywhere`) searches what's yours wherever it's
kept: your notes and todos, your mail and your chat messages, newest
first, as you type. It takes the same query language as each of them, and
`in:mail`, `in:chat` or `in:notes` picks some. Like this:

```text
lunch from:bea in:chat in:mail
invoice date:2w..
```

Any other `in:` goes on to the sources (a room in chat, a folder in mail).
Project files and shell history stay out, they have searches of their own,
and each app's own search box still searches only that app.

## Files and buffers

| Keys | |
|---|---|
| `space f` | Find a file in the project; in your home folder, not under Library, Music, Movies, Pictures, Applications or Public |
| `space F` | Find a file under the folder Greed was started in |
| `space '` | Open the last picker again |
| `space .` | What you can do with what's under the cursor (a file, link, symbol, problem, change or the selection), to pick one; `alt-.` in the vscode style |
| `space b` | Switch to an open file |
| `space space` | Switch to anything: files, shells, terminals and other buffers, and your other sessions and the agents in them on every machine you reach, each saying what it is. `@shell` (or `@sh`) keeps one kind, `@modified` those with unsaved changes, `@shown` those in a pane, `@agent` or `@session` those, `@waiting` the agents waiting for you and a machine's name (`@eris`, `@here`) what's there; the preview shows a shell or terminal at its end. `enter` goes there, `ctrl-a` lists what can be done to it (answer or stop an agent where it runs), and for a buffer `ctrl-v` opens it beside, `ctrl-s` below and `ctrl-f` in a float |
| `space j` | Pick a place from the jumplist |
| `space y` `space p` `space R` | Copy, paste and replace, as in Helix (copies always go to the clipboard here) |
| `space e` | File tree in a side panel |
| `space -` | This file's folder as text to edit: rename, make, move and delete files (see the file tree, below) |
| `:w` `:w PATH` | Save, or save as; an untitled buffer asks where to save it. Into a folder that isn't there it refuses; `:w!` makes the folder and saves |
| `:wa` (`:write-all`) | Save every file with unsaved changes; `:wa!` makes missing folders too |
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
| `:login PROVIDER`, `:logout PROVIDER` | Sign in to a model provider: with an account for plans that come with one, like Berget Code or Mistral's Vibe, or else with its API key (see [Models](#models)) |

Closing a terminal's buffer ends its program.

Saving writes a new copy beside the file and moves it into place, so a
crash or a full disk never leaves a file half written. The file keeps its
permissions, and saving through a symlink writes the file it points to. A
file that isn't UTF-8 opens read-only, with unreadable bytes shown as `�`;
`:w` refuses to write over it, since that would replace those bytes, and
`:w PATH` saves what you see to another file.

`greed bench [FILE]` measures how quickly keys show. It starts a session
with your plugins and config on the file (a large generated Rust file
without one), types and moves around, and prints per kind of key the time
from leaving the client to the frame showing it, the slowest named, and
where the time went (as `:profile` shows it). It also types into a
terminal, timing each character until its echo shows. `--draw` also draws
each frame in your terminal, as `greed` does, and reports how long that
took, how many bytes went out, and how long the terminal took to take
them in.

`greed shot [FILE]` saves the editor as the window would show it, with your
plugins and config, as a picture, for a bug report or to show a setup:

```bash
greed shot --keys ":" --type "board ops" --keys enter --size 1280x800 --out ops.png
```

Steps run in order: `--keys "space e"`, `--type TEXT`, `--run COMMAND`,
`--wait SECONDS` and `--wait-for TEXT` (until the screen shows it). Then
`--size 1280x800` and `--out PATH` (default `greed-shot.png`). `--run`
takes a command's name alone; for one with arguments, type it at `:` as
above. It needs no window, but a GPU or software Vulkan to draw with.

`greed --record SCRIPT [FILE]` records the editor the same way, every frame
a picture, for a video or screenshots. One step a line, `#` starts a
comment:

```text
size 1280 800          the pictures' size, before any step
scale 2                pixels per point, for sharper pictures
fps 30                 frames a second
typing 0.04            seconds between the keys `type` presses
output media/shell     where the frames and screenshots go (beside the script)
show-keys              show the keys each `keys` step presses, for a moment
hide                   stop keeping frames, while setting things up
show                   keep them again
caption Selections     a line over the screen until the next; `caption` alone takes it away
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

In the file tree:

| Keys | |
|---|---|
| `enter` `l`, a click | Open a file or fold a folder |
| `h` | Fold the folder you're in |
| `a` | Make a file in the folder under the cursor (end the name with `/` for a folder) |
| `R` | Rename or move what's under the cursor, taking files you have open along |
| `d` | Delete it, once you press `y` |
| `e` | Show the folder under the cursor as a buffer to edit (below) |
| `r` | Read the disk again |
| `q` | Close the tree |

Without the tree, `:file-rename NAME` renames the file you're in (a path
moves it, from the project's root), and `:file-delete` deletes it once you
press `y`. `:set tree-icons nerd` shows an icon by each name (see
[Icons](#icons)). Deleting moves things to the trash where there is one on
the same disk (`~/.Trash` on macOS, `~/.local/share/Trash` elsewhere), and
deletes them for good otherwise; `:set trash false` always deletes.

`space -` (or `:folder`) shows the folder of the file you're in as text, a
line per file and folder, to change many at once with the keys you edit
with: Helix's `s` and `c` rename every match, say. Edit a name to rename
it; add a line to make a file, ending it in `/` for a folder (`a/b.txt`
makes the folder too); delete a line to delete it. Cut a line in one
folder's buffer and paste it in another's to move the file, or paste it
while it's still in the first to copy it. `:w` lists what it will do and
does it once you press `y`, for every folder buffer at once, and
`:folder-undo` takes it all back. In a folder's buffer, `enter` opens the
file or folder on the line and `-` goes up; opening a folder from the
file picker or `:open` shows it this way too.

When a file changes on disk, from another program or an agent, its buffer
loads the change as an edit you can undo with `u`. A buffer with unsaved
changes is left alone and Greed tells you; `:reload` loads the file into it
anyway. `:set auto-reload false` turns this off.

`:set auto-save true` saves a file a second after you stop editing it, so
a burst of typing is one save; `:set auto-save-delay 3000` waits three
seconds. It saves quietly and skips formatting, as Helix does: formatting
while you pause would change the line you're typing, like a trailing
space gone just before your next word. To keep it, in your `init.luau`:
`require("@greed").option.set("auto-save", true)`.

### Icons

The file tree's icons and the status line's rounded ends come from
[Nerd Fonts](https://www.nerdfonts.com). The window (`greed --gui`) has
them built in, whatever font you draw in, even when another installed font
claims the same characters. A terminal shows them only if its font has
them: install a Nerd Font, or one of its icon-only "Symbols" fonts, and
set your terminal to use it. Without one you see boxes.

In the window, emoji come from your system's emoji font; one it can't draw
in color, like the newest Noto Color Emoji, is passed over for another, or
the plain Noto Emoji.

Two options use them. By default `tree-icons` is `"none"`, and the rounded
ends show only once `statusline-pills` is on (see [The status
line](#the-status-line)).

```luau
local option = require("@greed").option
option.set("tree-icons", "nerd") -- "none" for no icons
option.set("statusline-caps", "round") -- "none" for square ends
```

Setup turns icons on when run in the window, or when you say the terminal
shows them. The window and terminals share one config, so if you set
Greed up in the window and later use a terminal without a Nerd Font, set
both options back to `"none"`.

## Debugging

Debug topics log what happens inside, for keys going missing or a pause;
`:debug-log` shows the log as it comes. Turn a topic on, do the thing
again, and read the log:

| Topic | What it says |
|---|---|
| `keys` | Each key from each client, what it ran (or that it isn't bound), and how long it waited behind a command at work |
| `runs` | Every run of plugin code: the plugin, what it ran, how long it took |
| `frames` | Each frame built for a client, how long that took, and whether all of it was sent or what changed |
| `rpc` | Messages to and from language servers and other JSON-RPC programs |
| `jobs` | Programs plugins ran, how long they took and how they ended |
| `client` | The terminal's or window's side: keys and input method events as the system gave them, focus, and how long drawing each frame took |
| `plugins` | What plugins say with `greed.debug.log`; `plugin:NAME` for one |

| Command | |
|---|---|
| `:debug keys client` | Turn two topics on |
| `:debug -client` | Turn one off |
| `:debug off`, `:debug all` | Turn all off, or all on |
| `greed.debug.switch("keys frames")` | In `init.luau`, to catch what happens at start |
| `GREED_DEBUG=keys,frames greed` | The same from the shell; a session started in the background gets it too |
| `greed ctl debug_log` | Read the lines from an agent or script (`set=keys` turns topics on, `after=ID` reads only newer lines) |

A topic that's off costs next to nothing, so they stay in release builds;
one that's on keeps its last 10 000 lines in memory.

## Language servers

Greed knows some 340 languages (files, comments, indentation, servers),
most from [Helix](https://helix-editor.com)'s list, and starts a language
server when a file needs one and it's installed. `:health` shows each
language's server, whether it was found, and the servers running. Without
a server nothing complains until you ask for something only a server can
answer, like `g d`; then it says which program to install.

Each project gets its own servers, so two projects (or two jj workspaces
of one) are checked separately. A server runs in the topmost folder of the
project that has one of the language's root files (`Cargo.toml` for Rust,
`package.json` for TypeScript), so one server covers a whole Cargo or npm
workspace; without one, it runs in the project's root. A crashed server
starts again, up to three times in a row; `:lsp-restart` restarts this
file's server (`:lsp-restart all` every one). Servers that support it get
only what changed with each edit.

A server's own settings go on its language, named as its documentation
names them, and `init_options` for what it's started with:

```luau
require("@languages").set("rust", {
	settings = { ["rust-analyzer"] = { cargo = { features = "all" } } },
})
```

A running server keeps the settings it started with; `:lsp-restart` gives
it the new ones.

| Keys | |
|---|---|
| `space k` | What's under the cursor, with any problems there, drawn as Markdown: code in its language's colors, links to follow |
| `g d` | Go to the definition |
| `g D` `g y` `g i` | Go to the declaration, the type's definition, an implementation |
| `g r` | Pick a place it's used, with a preview |
| `space H` | Select every place in this file it's used (Helix's space h, which is help here) |
| `space S` | Pick a symbol anywhere in the project |
| `:rename` | Rename it everywhere it's used (`space r`; also `g r n` in the Vim style, `f2` in the vscode style) |
| `space a` | Pick a fix or refactor for the cursor or selection, or what a plugin offers there, like linking a note the line mentions |
| `space d` | Pick a problem in this file |
| `space D` | Pick a problem in any file the server checked, open or not |
| `] d` `[ d` | Next and previous problem; `] D` `[ D` the last and first |

Problems are underlined, and their lines get a sign and a colored line
number. Each line's worst problem also shows after the line's end; `:set
diagnostic-messages false` hides those. They move with your edits until
the server checks the file again. The signs are `E`, `W`, `I` and `H`;
`require("@lsp").signs.error = "●"` changes one (`warning`, `info` and
`hint` for the others), from the server's next check.

In the `g r` and `space D` lists, `ctrl-e` puts the places in a panel like
the project search's, to edit the same way: each reference with a line
around it, or each problem's line with its message beside the file name
(two on one line get a line each; one too long for the panel ends in `…`).

A rename or code action that changes other files opens them in the
background, unsaved, so you can look the change over (`space b`) and undo
it before saving.

Completions show in a menu at the cursor once typing pauses after a letter,
a `.` or a `/`. The menu narrows as you type: what starts with what you
typed first, then what holds it, then looser matches. What the language
server offers comes first, then words from your open files once you've
typed two letters, so a file with no server still completes names you've
used. A path you're typing, starting `./`, `../`, `~/` or `/`, completes
from its folder instead (from the file's folder for `./`), and a `/` after
a folder lists what's in it.

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

Some completions are snippets, with places to fill in, like a function's
arguments. Taking one selects its first place: typing replaces what's
there, `tab` goes to the next place and `shift-tab` back, and a place used
twice fills in both at once. A place with choices, `${1|let,const|}`,
starts with the first and offers the others in the completion menu. The
snippet ends at its last place, or when you leave insert mode.

Snippets use VS Code's format, so VS Code snippet files and sets like
friendly-snippets work as they are: choices, variables and transforms
included. Your own go in one file per
language in the `snippets` folder of your config, like
`~/.config/greed/snippets/rust.json`, and a project's in
`.greed/snippets/`. `all.json` is for every language, and a
`.code-snippets` file may give each snippet a `scope`, like `"rust,go"`.

```json
{
  "test": {
    "prefix": "test",
    "body": ["#[test]", "fn ${1:name}() {", "\t$0", "}"],
    "description": "A test function"
  }
}
```

A snippet comes up in the completion menu as you type its prefix, after
what the language server offers. `:snippet` picks one by name, and
`:snippets-edit` opens the file for the language you're in, making it if
it isn't there; saving it takes effect at once. In a body, `\t` is a level
of the file's indent, and `$TM_FILENAME`, `$CURRENT_DATE` and VS Code's
other variables work, with VS Code's transforms: in `user_profile.rs`,
`${TM_FILENAME_BASE/(.*)/${1:/pascalcase}/}` is `UserProfile`.

Typing `(` or `,` in a call shows the function's parameters above the
cursor, the one you're on picked out, until the call closes or you leave
insert mode. To ask for it with a key, bind `signature-help` in insert
mode:

```luau
greed.keymap.bind({ role = "typing" }, { ["ctrl-k"] = "signature-help" })
```

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

`space g s` shows each change in every file under the file's name, with a
couple of lines around it: added lines in green, removed ones in red where
they were. With git it shows what's not staged yet. It's a multibuffer like
the project search's results: edit the changes and `:w` saves the files,
`space g r` on a change puts it back, `space g a` stages that change, and
`enter` goes to it in its file. New files show whole; deleted ones are left
out.

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

An operation is a piece of work across files, kept as one: a rename an
agent did in 14 files, a plugin's refactor, the changes you accepted from a
proposal. Its edits in every file undo together, and you can review it in
one buffer.

| Keys | What it does |
|---|---|
| `space u o` (`:operations`) | Pick a recent operation to review |
| `space u u` (`:operation-undo`) | Undo the latest operation, in every file at once |
| `space u c` (`:operation-commit`) | Save the latest operation's files and commit only them, named after it |

The review is a multibuffer of the operation's changes, with the programs
it ran (a test run, a formatter) and how they exited at the top. Edit it
like any multibuffer, `space g r` puts a change back, and `space u u` in it
undoes that operation.

If you've edited its files since, undo keeps your edits: it puts back the
operation's changes you haven't touched, leaves the ones you have, and
says how many it left. Operations are kept across restarts (in the cache
folder), so yesterday's agent work can still be reviewed and undone.

`space u c` saves the operation's files and commits only them (a jj
change, or a git commit) with the operation's name as the message; your
other changes stay where they were. In a review it commits the operation
shown.

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

The model question in `:setup` moves the roles to another provider at
once (OpenAI, Berget, Mistral or Ollama, each with models it suggests), and
in `:models` any role can use any provider's model.

Other roles fall back to these until you set them:

| Role | Used for | Until set |
|---|---|---|
| `agent` | Greed's own agent | `reasoning` |
| `review` | Reviewing code an agent wants to run | `reasoning` |
| `compact` | Compacting a long conversation of Greed's agent | `agent` |
| `decision` | Auto mode: whether an agent may run a command it can't tell is safe | `fast` |

A small model made for yes-or-no answers, like the decision models Berget
offers, suits `decision` (see [Auto mode](permissions.md#auto-mode)).

`:models` shows every role, its model and whether its provider's key is
found, and lets you change them:

| Key | |
|---|---|
| `enter` | Pick the provider and model for the role under the cursor, from the models the provider lists; asks for the key if it needs one |
| `e` | Pick how hard the role's model thinks before it answers: `none`, `low`, `medium`, `high`, or unset |
| `k` | Set the API key of the role's provider: it goes in the system keyring, or Greed's secrets file where it can't be reached |
| `l` | Sign in to the role's provider, for those with an account instead of a key, like Berget or Mistral (with Vibe) |
| `q` | Close |

The model picker lists what the provider offers (for Ollama, the models it
has pulled), the role's current or the provider's suggested model first;
type to narrow it down. `enter` on a name that matches nothing takes it as
typed, and "type a name…" asks for one. When there's no list, say without
a key yet or with the server down, Greed says why and asks for the name.
Lists are kept for ten minutes.

What you pick is kept in Greed's data folder. Your `init.luau` is read
after it, so a role set there wins, and `:models` says "(set in your
config)" beside it. Instead of a key in `:models`, set the variable it
names, like `ANTHROPIC_API_KEY`, or run `:secret-set anthropic`. Anything
that needs a model and has no key says which variable sets it, and that
`:models` adds one.

Keys and sign-ins go in the system keyring through `secret-tool` on Linux
(`security` on macOS). When Greed can't reach it (`secret-tool` isn't
installed, or there's no D-Bus session), a key kept there looks missing,
and the message says the keyring couldn't be reached and why. New keys and
sign-ins then go to Greed's own secrets file, and Greed says so; keys there
are found whether the keyring answers or not.

`:usage` shows the tokens the models were sent and wrote, as the providers
reported them for Greed's agent and the features with tools: today, by
model, and each day of the last week. Tokens read from the provider's cache
show apart, as "(52.1k cached)"; they cost a fraction of the rest, so a low
share means caching isn't working. Under each model it shows how many of
Greed's agent's edits worked, by the way it made them. It's kept a file a
day in Greed's data folder (`usage/2026-10-09.json`), by hour and model.

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
`"none"`, `"low"`, `"medium"`, `"high"` or `"max"`. Unset, nothing is sent
and the model uses its default. A provider's `effort` is the default for
its roles.

```luau
models.roles.agent = { provider = "mistral", model = "mistral-large-4", effort = "high" }
models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", effort = "low" }
```

`e` in `:models` picks it and keeps it with the role, whose line shows it.
In Greed's agent, `/effort` changes it for one session (see
[Agents](agents.md#slash-commands)). How it's sent:

- Servers with OpenAI's API get it as `reasoning_effort`, up to `high`
  (`max` is sent as `high`).
- A provider that takes only some sets `efforts`, and the nearest is sent:
  the `mistral` provider takes `none` and `high`, so `low` is sent as
  `none` and `medium` as `high`, and `:models` says so ("effort low (sent
  as none)").
- Some models take their own whoever serves them: GLM 5 always thinks and
  takes `low`, `high` and `max`, so `none` is sent as `low` and `medium` as
  `high`.
- Claude models get it as their effort, with their thinking summarised so
  Greed's agent can show it; models before Claude 4.6, like Haiku 4.5,
  think within a budget instead (2k, 8k or 24k tokens, `max` the same as
  `high`).

Greed's agent sends the whole conversation each turn, and providers charge
far less for the part they've cached. Some, like Mistral, only cache a
request that names its conversation: `cache_key = true` on a provider has
Greed's agent send its session's id as `prompt_cache_key`. The `mistral`
provider has it on. `:usage` shows how much was cached.

Mistral's reasoning models work better when they get back what they
thought before each answer: `thinking_back = true` on a provider sends it
back with what the model said, and the `mistral` provider has it on. It
takes room in the conversation, so it's compacted a little sooner.

To see which requests missed the cache, `:debug plugin:models` logs a line
for each in `:debug-log`:

- the provider, model and session id, and how many messages it sent;
- a short hash of all of it but the newest message, and what it changed of
  the session's last request (nothing, when it's that one with more on the
  end);
- the tokens sent, read from the cache and written;
- the time until the first bytes came back, the total time, and tokens a
  second while it streamed.

A request that starts with all of the last one and still shows little
cached was missed by the provider. A long wait for the first bytes is the
provider (queueing, or reading a long uncached conversation); a low pace is
the model writing slowly, or thinking.

A model's answer that goes quiet for 90 seconds counts as failed; the
first bytes get three times as long, since a long uncached conversation or
hidden thinking can take minutes. `:set models-idle-timeout 180` changes it
for all of them, `idle = 180` on a role or provider for its models (a slow
local one, say), and `0` waits for ever. The `mistral`, `ollama` and
`berget` providers wait ten minutes: they send a tool call whole once the
model has written it, so a long file is a long quiet.

```luau
models.providers.ollama.idle = 600
```

A request that timed out, lost its connection, or was turned away as too
busy (429, 502, 503 or 504) is sent once more after a moment, or as long as
the server's `Retry-After` says, up to 30 seconds. It isn't sent again once
some of the answer was shown, as the second answer would repeat it.

A provider with a `secret` reads its key with `:secret-set NAME`, or from
`GREED_SECRET_NAME`. The built-in providers send their keys only to their
own servers. The first time any other key would go to an address, Greed
asks (`y` yes, `n` no) and keeps your answer, so a plugin can't add a
provider that sends your key somewhere you didn't choose.

Some plans come with an account instead of a key, like Berget Code.
`:login berget` shows a link and a code; approve it in a browser on any
device, and the `berget` provider uses that sign-in from then on, renewing
it as needed. `:models` says "signed in (Berget Code)"; `:logout berget`
forgets it, and the provider goes back to its key.

```luau
models.roles.agent = { provider = "berget", model = "the model you want" }
```

With a Le Chat Pro or Team plan, sign in to Mistral with Vibe, as Mistral's
`vibe` command does: `:login vibe` (or `:login mistral` and pick Vibe)
shows a link; sign in and pick a workspace there, and Mistral makes an API
key for Vibe, kept as your `mistral` key. Requests with it count against
your plan's allowance instead of API credits; past that, your plan's
pay-as-you-go applies, at API prices. `:models` says "signed in (Vibe)",
and `:logout vibe` forgets the key (unless you've set a key of your own
since). It's an ordinary API key with nothing to renew; Mistral's console
shows it and can revoke it.

For a key you already have, `:login mistral` and picking an API key keeps
it (or set `MISTRAL_API_KEY`). Either way, the `mistral` provider uses
Mistral Large 4 for `reasoning` and Mistral Small for `fast` when picked in
`:models`, and Mistral's `mistral-vibe-cli-latest` is the model Vibe itself
uses:

```luau
models.roles.agent = { provider = "mistral", model = "mistral-large-4" }
```

Mistral also serves Z.ai's GLM 5.3 as `zai-glm-5-3`: a million tokens of
room, text only, and it always thinks, at `low`, `high` or `max` (see
efforts above). Its thinking goes back to it each turn like Mistral's own
models'.

```luau
models.roles.agent = { provider = "mistral", model = "zai-glm-5-3", effort = "high" }
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
| `space i i` | Show what's pinned, one item a line with its size in tokens; `d` drops the items on the lines selected (`x d`) |
| `:context-add-problems` | Pin this file's problems from the language server |
| `:context-add-diff` | Pin the changes in progress |
| `:context-clear` | Drop everything |

Anything you can inspect pins too: `pin to context` is among every
object's actions (`space .`, or the inspector), so a pod, a shell block or
a terminal goes with your messages, in its state at the time of each one.

Items are read fresh each time they're sent: a pinned selection follows the
text as you edit, the diff is the current diff, and a pinned pod is its
row from the newest block that lists it. The assist commands send the
context with each question. The agent pane sends it with a message when it
changed since the last one, so a pinned file goes again only after an
edit; other agents read it with the `context_get` tool. Each project keeps
its context across restarts, except pinned objects, which belong to the
session.

## Formatting

Saving a file formats it; `:format` formats without saving. Greed uses the
language's formatter when it's installed (`gofmt`, `ruff`, `stylua`,
`prettier`, `shfmt`, ...), otherwise the language server (Rust gets
`rustfmt` through rust-analyzer). Only what the formatter changed is
replaced, so the cursor stays put. If you type while a slow formatter
runs, its result is left out rather than undoing what you typed.
Auto-save doesn't format; the next `:w` does.

```luau
-- A different formatter for a language
require("@languages").set("python", { formatter = { "black", "-q", "-" } })

-- No formatting on save
require("@greed").option.set("format-on-save", false)
```

A formatter gets the text on its input and prints it formatted; `{path}` in
its command stands for the file's path.

## Markdown

Markdown files show as documents. The file stays plain Markdown.

- Headings show without their hashes, a top-level one twice the size,
  and each level in a color of its own (`markdown.heading.1` to `.6` in a
  theme).
- `**bold**`, `*italic*`, `~~struck~~` and `` `code` `` show without their
  markers, links as their underlined text.
- Fenced code gets a background of its own and keeps its markup: a
  `# comment` there stays code.
- Quotes get a bar, `---` a line, list bullets (`-`, `*` or `+`) dots, and
  tables aligned columns with borders.
- Obsidian's callouts, a quote starting `> [!warning] Mind the step`,
  show their sign and title (or their kind, `Warning`, without one), the
  bar in their kind's colour: note and info, tip, success, question,
  warning, danger and error, example and quote.

While you type on a line (insert mode) it shows as written; otherwise
markup shows as written once the cursor steps inside it. A field, a box or
a button stays drawn while the cursor is on its first character, so
`enter` presses it; one step further in (`l`) opens it to edit with the
usual keys. Table borders open only while typing. `:set markup-reveal
never` keeps markup drawn outside insert mode.

The window draws big headings big and sets text in a proportional font
(code and tables stay monospaced). Terminals other than kitty show
headings at the normal size.

| | |
|---|---|
| `:set markdown-look false` | Turn the look off everywhere |
| `space m l` (`alt-V` in the vscode style, `:markdown-look-toggle`) | Toggle it for this file: as written, or as a document while the option is off |

The status line shows `markdown · plain` while a file shows as written.

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

Following a link:

- `#a-heading` goes to that heading.
- Another Markdown file opens in the reading view too, at its heading with
  `other.md#a-heading`.
- A web or mail link opens in your browser or mail program (the
  `link-opener` option says which).
- A `file://` link opens the file in Greed.

Links of other kinds don't open, since any file you read could hold them.

### Tables

A table is edited as it's drawn, from normal mode. `h` and `l` step over
the pipes and padding, `j` and `k` keep to the column you see, and
`alt-h` and `alt-l` go a whole cell back or on, row after row (outside a
table they still move between panes). `enter` on a cell asks for its text;
in a column a [formula](#live-values) fills, it asks for the formula. The
rest is on the leader:

| Keys | |
|---|---|
| `space m t o`, `space m t O` | Add a row below or above |
| `space m t d` | Delete the row |
| `space m t j`, `space m t k` | Move the row down or up |
| `space m t c`, `space m t C` | Add a column right or left |
| `space m t D` | Delete the column |
| `space m t l`, `space m t h` | Move the column right or left |
| `space m t s`, `space m t S` | Sort the rows by the column, smallest or largest first |
| `space m t =` | Line up the pipes |
| `space m t e` | Edit the cell, as `enter` does |

Each change writes the table back with its pipes lined up and is one step
to undo. When you type in a table yourself, leaving insert mode lines it up
again and fills out a row you typed short of cells, so its formula columns
show. The keys are in
`require("@markdown").table_edit.keys`, to rebind like any others.

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

Choices and runnable blocks make a page of questions that acts on the
answers and still reads as plain Markdown. HTML comments, which GitHub and
the like don't show, hold the rest:

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
  them as JSON in `ANSWERS`, and `ANSWER`), and `values`, all the page's
  [live values](#live-values): fields, `let`s, answers, and named tables as
  lists of their rows. Programs get those as JSON in `VALUES`, and each
  number or text by its name too, so a `sh` block can `echo $bill`.
  For a button whose output stays in the file, a block with
  `button="Label"` is the way; a `run:` link's shows in a float.
- `<!-- if NAME=VALUE -->` to `<!-- end -->` is a part that shows only for
  that answer (`!=` for any other), or for any of several, as in
  `<!-- if style=vim,helix -->`. Its questions don't count otherwise.
  A hidden part leaves its `if` line, which says when it shows
  (`▸ shows if trip is abroad`); with the cursor on that line the part
  opens, dimmed, to read and edit without changing the answer.

Blocks that make choices or hear picks are hidden, and buttons show as
buttons: put the cursor there to see their code. They run as any block
does: in a file you haven't trusted, the first asks whether to. A Luau
block can't wait, so one that asks for something, like a prompt or a
secret, does it in `greed.spawn`. Greed's own setup page, `setup.md` in
the `setup` plugin, is a questionnaire like this.

### Live values

Formulas in Luau's syntax work values out as you change the file:

```markdown
Bill: [840](field:bill) kr, we're [3](field:people) people.

<!-- let tip = bill * 0.1 -->
Tip: {{ fixed(tip) }} kr. Each pays {{ fixed((bill + tip) / people) }} kr.

<!-- id=items -->
| Dish  | Price |
|-------|-------|
| Pasta | 240   |
| Wine  | 210   |

{{ count(items.dish) }} dishes, {{ sum(items.price) }} kr in all.
```

- `{{ formula }}` shows what the formula works out to. With the cursor on
  its line you see the formula, to edit it.
- `[840](field:bill)` is a field: its value is the text between the
  brackets, shown as a box. `enter` on it, or a click, asks for a new one
  and writes it in the file, and every value from it follows. `space m f`
  makes the number or word at the cursor (or what's selected) a field,
  asking for its name, and on a field renames it.
- `<!-- let name = formula -->` names a value for formulas anywhere in
  the file.
- A table with `<!-- id=name -->` right above it is a value too: `items[1]`
  is its first row, `items[1].price` a cell and `items.price` the column,
  by the header's words in lowercase with spaces as `_`.
- A [named question](#questionnaires)'s answer is a value by its name.

A table's column can be worked out too, row by row, with a formula line
right under the table:

```markdown
<!-- id=costs -->
| Item | Amount | Per year | So far |
|------|-------:|---------:|-------:|
| Rent | 900    |          |        |
| Food | 350    |          |        |
<!-- formula: per_year = amount * 12 -->
<!-- formula: so_far = (if prev then prev.so_far else 0) + amount -->
```

A formula names its row's cells by their column, `prev` for the row
above, and anything else in the file. Its column's cells can stay empty:
they show what it works out, and whatever they say in the file gives way.
Formulas go in order, so a later one can use an earlier one's column, and
the table's value has them too (`sum(costs.per_year)`).

A chart line under a table, after any formula lines, draws it:

```markdown
<!-- chart: bar per_year -->
```

What follows `chart:` is what follows `| chart` in the shell (`bar`,
`line`, `area`, `scatter`, a column to chart, `--height`, ...), and its
columns are named as formulas name them. The chart follows the table as
you change it and the values it uses; on GitHub only the table shows.

A command button runs a command in the project's shell and shows its output
in a float as it comes (`esc` closes it, `ctrl-c` stops it). It runs with
`sh` whatever shell you use, so it works the same for anyone you share the
file with:

```markdown
Crate: [greed-core](field:crate)

[Run its tests](run:cargo test -p {{ crate }})
```

A `{{ formula }}` in the command goes in as one quoted argument, so a
field can't add to the command whatever it holds. For output that stays in
the file under the button, use a code block with a button; it gets the
page's values as variables:

````markdown
```sh button="Run its tests"
cargo test -p "$crate"
```
````

The label hides the command, so the first press shows it and asks: `y`
runs it this time, `a` always. A command changed since (in the file, by a
pull or an agent) asks again.

Formulas are expressions only: arithmetic, comparisons, `and`/`or`/`not`,
`..` to join text, `if a then b else c`, and functions: `sum`, `avg`,
`count`, `min`, `max`, `round(x, digits)`, `floor`, `ceil`, `abs`,
`fixed(x, digits)` (a number with that many decimals, 2 unless said),
`upper`, `lower` and `empty`, plus any a plugin adds. They can't run
anything or loop, so they work in any file without asking, and one that
goes wrong shows why where its value would be. On GitHub and the like, a
field shows as a link and a value as its formula.

### Data blocks

A fenced block named after a data source shows the table it reads, live,
under it:

````markdown
City: [oslo](field:city)

```sqlite db=shop.db rows=10 id=customers
SELECT name, total FROM customers WHERE city = @city ORDER BY total DESC
```
<!-- chart: bar total -->

The best customer: {{ customers[1].name }}.
````

Its first line says what it reads and how it went (`▦ sqlite · shop.db · 10
rows`), and the query folds under it: with the cursor on that line it shows,
dimmed, to edit. The table is read again a moment after what it asks
changes, and when the file it reads changes. Reading runs in the
background, so typing never waits for it.

| Source | Reads |
|---|---|
| `csv` | a CSV file with a header (`path=sales.csv`, from the document's folder), or the block's own lines |
| `sqlite` | a query over the SQLite database `db=FILE`, by the `sqlite3` program |
| `psql` | a query over PostgreSQL by `psql`, `db=` a connection (else psql's own settings) |

- `@name` in a query is the document's value of that name (a field, a `let`,
  an answer), passed to the database as a parameter, never pasted into the
  query: a field holding `'; drop table customers; --` is only text. Change
  the field and the table is read again.
- `rows=N` shows N rows at a time; `space m n` and `space m p` turn the page.
- The table is drawn, so the cursor goes past it. `enter` on it, or
  `space m o`, opens it in a float as text, a page at a time, to search and
  copy; `enter` on a row shows the whole record and `q` closes it.
- `id=NAME` makes the table a value for formulas, as a named Markdown table is
  (`customers[1].name`, `sum(customers.total)`), and a `<!-- chart: ... -->`
  line under the block charts it.
- `sqlite` and `psql` open the database read-only unless the block says
  `write=true`. They run programs, so a block waits, as a code block does,
  until you let it: `enter` on its first line asks, `a` lets the file's data
  blocks run from then on. `enter` there later reads it again.
- The programs are `sqlite3` and `psql` unless `:set data-sqlite3` or
  `:set data-psql` names others.

In the shell, `data SOURCE ...` reads the same sources into a block's table, so a
board's cards can show them too (see the shell's "Databases and files").
Plugins add sources with `require("@core").data.source({ name, read, ... })`;
see `core.data` for what a source gives.

### Runnable code blocks

A fenced block in a language Greed can run runs when you ask, and its
output is saved in a `result` block right under it, so it shows wherever
the file is read and a diff shows what changed. Running a block again
replaces its result.

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
  a URL alone, for GET), then header lines, then after a blank line the
  body. The result is the status and the body; `headers=true` adds the
  response's headers.

Options go after the language:

- `id=NAME` names a block, and `input=NAME` gives another block that
  block's result: on stdin for a program, as `input` in Luau, and into
  the first line of a `shell` block, so `where STATUS != Running` alone
  works on it. The named block runs first if it has no result yet, so a
  page of blocks works like a small pipeline. With `rerun=true` on the
  block taking the input, its input runs again every time, so it never
  reads a stale result.
- `dir=PATH` runs a program in another folder than the file's.
- `timeout=SECONDS` stops it after that long.
- `every=SECONDS`, on a `shell` block, keeps it live (above).

While a block runs, its fence shows `■ running`; click that or press
`space m s` to stop it, along with anything it started, like a server. A
result keeps at most `blocks-max-lines` lines of output (1000).

Nothing runs when a file opens. The first time you run a block in a file,
Greed asks whether to:

- `y` runs it this time; `a` always trusts that file (`:blocks-untrust`
  takes it back).
- Trusted files, and files whose front matter says `greed: run`, show a
  `▶ run` button after each block's fence. Front matter only shows the
  buttons; running still asks. The status line shows `markdown · blocks`
  when they're on.
- Agents can list and run blocks too (`blocks_list`, `blocks_run`), only
  in files you trust, and only blocks as they were when you last ran them
  yourself or trusted the file (`a`, or `:blocks-trust`). A block an agent
  changed, in the buffer or on disk, doesn't run for an agent until you've
  run it, and neither does a block taking its input from one.

Trust covers what a file holds when you trust it. What runs by itself
(choices made as the file opens, a block a pick runs, a board's cards)
runs only as you last let it run. When the file changes from outside, as
after a `git pull` or an agent's edit, a changed block waits until you run
it yourself (`space m r`), and a changed card on a board shows the command
it would run and waits for `enter`. What you write or change yourself and
save may run as it is.

Add a language from Luau:

```luau
local blocks = require("@blocks")
blocks.runner("lua", blocks.program({ "lua", "-e" }))
```

## Notes

[Hoard](hoard.md) (`greed notes`) shows your notes and todos on a home page
for anyone to use; this section is about notes in the editor.

Notes are Markdown files in a folder (`~/notes` unless you set
`notes-folder`), so git or Syncthing can carry them between machines and to
your phone. Link one to another with `[[name]]`, or `[[name|other words]]`
to show other words.

| Keys | |
|---|---|
| `space n h` | Go to Hoard, your notes and today's things to do, in its own session (started if needed; `space B` comes back); `space n H` opens it in a window of its own ([Hoard](hoard.md)) |
| `space n d` | Today's note, in `daily/` |
| `space n c` | Add a todo to the inbox, from wherever you are: the project's when it keeps notes, otherwise yours (`:notes-capture-mine` always yours). It can say when in plain words, like `call the bank tomorrow 18:00` or `water plants every monday` ([more](hoard.md#saying-when-in-plain-words)) |
| `space n a` | The agenda: open todos from every note, soonest due first |
| `space n f` | Find a note; a name that isn't one yet makes it |
| `space n /` | Search every note as you type |
| `space n x` | Tick a todo or untick it; a plain line becomes one |
| `space n t` | Jot a thought or an idea down in the inbox, with today's date: for things that aren't todos |
| `space n r` | Dismiss the reminders notice (below) |
| `space k` | On a due date or a reminder, say when it is in words ("tomorrow, 18:00, in 25 hours") |
| `space n l` | Have Greed's agent connect the inbox (or the note you're in) to your other notes (below) |
| `space n k` | Link to a heading, a list item or a block in any note, picked from all of them ([more](hoard.md#links-embeds-and-obsidian)) |
| `space n n` | Make a note from a template: pick the kind, then name it ([more](hoard.md#templates)) |
| `space n y` | Give the note you're in a template's fields it doesn't have yet |
| `space n j` | Pick a job for Greed's agent on your notes: connect, pull out todos, ask, sum up the week |
| `g d` | Follow the link under the cursor, to the heading or block it names, making the note if it's new; in Markdown outside your notes, `[[name]]` is `name.md` beside the file |
| `z a` | Fold the section under the cursor, or unfold it (any Markdown) |
| `alt-up` `alt-down` | Move the list item (with the items under it) or section the cursor is in past the one beside it (any Markdown; the vscode style's keys, `move-lines-up` and `move-lines-down` in others) |
| `space z`, `space Z` | Zoom in to the list item or section the cursor is in, showing only it; zoom out again |

A todo is a list item with a box, `- [ ] call the bank`, and
`due:2026-10-03` anywhere in it gives it a date for the agenda. Notes and
todos are objects too: `space h i` on one shows its note, due date and
reminders, and `space .` opens or ticks it, for agents as well. In a note,
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
computer's local time. Ticked todos don't remind you. A line can have as
many reminders as you like, each going off at its own time:

```markdown
- [ ] pay the invoice due:2026-10-07 remind:2026-10-06 19:00 remind:2026-10-07 12:00
```

A time alone, `remind:10:30`, goes off on the line's own days: a todo's
due date, each day a repeating line (`every:weekday`) comes up, or every
day. Repeats, habits and `from:`/`until:` are in
[Hoard](hoard.md#repeats-habits-and-reminders).

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
goes off once. When several on one line went off while it wasn't running,
the line shows once. The reminders in your own notes go off in Hoard's
session, which starts with Greed when you have notes, and a project's in
that project's session, so none goes off twice; the hub tells you of them
wherever you are.

The status line says how many todos are due today, like `2 due today`, in a
warning color when some are overdue (`1 overdue, 2 due today`). Click it to
open the agenda.

Agents can set reminders too: ask Greed's agent to "remind me this evening
to call the bank" (see [Agents](agents.md)).

### Connecting your notes

`space n l` has Greed's agent go through your inbox (filled by `space n t`
and `space n c`), or the note you're in, find the notes each item relates
to, link them with `[[name]]` and add a line of context. Changes to
existing notes come as proposed edits you accept or reject one by one. It
makes new notes for items that belong together and ends with a summary. It
uses the model playing the `agent` role. `space n j` has other jobs for it:
pulling the todos out of a note, answering a question from your notes, and
summing up the week ([more](hoard.md#having-the-agent-help)).

Any agent can work with your notes the same way through the `notes` tool
group (see [Agents](agents.md#tool-groups)); `:set agent-tool-groups "plan
notes"` gives it to every agent from the start. Agents reach only the notes
in your note folders, by name: `../x` and other names leading out of them
are refused. Rewriting a note that's there comes to you as a proposal,
adding a line or a todo goes straight in, and decisions can only be
proposed with `decision_propose`.

### Notes in a project, and other places

A project can keep notes of its own in `.greed/notes/` (or wherever
`notes-project-folder` says, inside the project). Once the folder exists,
its notes are found, searched and linked with yours, their todos are in
the agenda, and capture puts todos in the project's inbox. Their names
start with `project:`, like `project:plan`; a link in a project note goes
to a note beside it first, so `[[design]]` there means `project:design`
when there is one. The plan and decisions you share with
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
markup, and the agenda leaves out todos in them. The file stays plain
Markdown: while you type on a line (insert mode), it shows as written; in
the vscode style, markup shows once the cursor is inside it. Click a box
or press `enter` on it to tick it; a heading's symbol folds its section.

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
| `ctrl-\`, `esc esc` | Stop typing into the program, to move around its output; one `esc` still goes to the program. For a program on the normal screen, like Claude Code, the first `esc` waits a moment, so `esc esc` reaches it not at all; full screen programs like editors get it at once (`:set terminal-esc-wait false` sends it at once everywhere) |
| `ctrl-space` | The same, then open the leader: `ctrl-space f` finds a file from inside a terminal |
| `alt-p` and the other `alt` pane keys | Work as in any pane: `alt-p x` (or `:q`) closes the terminal's pane or float, ending its program unless another view shows it |
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

A shell is a buffer with a prompt at the bottom; `enter` runs the command
typed there. Each command becomes a block above the prompt (the command,
what it printed and how it ended) that you can search, fold, copy, run
again and send to the next command or to a buffer:

```text
$3 | sort
cargo test > buf:tests
```

| | |
|---|---|
| `:shell` | Open a shell |
| `space o s` | Switch to one |
| `space o w` | What's running in every shell: `enter` opens one in a float, `ctrl-o` goes to it, `ctrl-x` stops it |

Agents run their commands there too. Programs a shell runs that want an
editor, like `git commit`, open the file in Greed (`$EDITOR` is `greed
edit --wait` there; `:set shell-editor false` turns that off).
[The shell](shell.md) has the rest: keys, builtins, which shell runs a
line, terminals, and limits.

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

On a Mac, `alt` is Option, which also types characters of its own (`π`,
or `[` and `{` on a Swedish keyboard):

- In the window, Option with a key is the `alt` key where that's bound,
  and types its character otherwise. Characters like `[ ] { } | @ $ \`
  are always typed. With Shift, letters work as `alt` keys (`alt-F`),
  other keys type their character.
- In a terminal, the terminal decides (iTerm2, kitty, Ghostty and others
  can treat Option as Alt).
- Command with a key is for the Mac and the menus (⌘V pastes, ⌘Q quits);
  the editor leaves it alone.
- A keyboard in Windows layout may send Command from the key labelled
  Alt: switch it to its Windows mode, or swap the two in
  System Settings > Keyboard > Modifier Keys.

To act on a pane without moving to it first, `alt-p g` puts a number over
each pane; type one to go there, and you're still in the pane mode, so
`alt-p g 3 f` zooms the third pane and `alt-p g 3 x` closes it; `esc`
leaves the pane mode. `ctrl-w g` and `space w g` label them too. While a
pane is zoomed the status line says "zoomed".

Floating views belong to the tab they opened in: switching tabs hides them
and closing the tab closes them. Floats `alt-f` hid come back where they
were, and hidden terminals keep running. `:float-file PATH` opens another
file as a floating view, as `alt-F` does this one. `alt-p e` takes the
pane or panel you're in out to float over the tab, or puts a floating view
back in as a pane; floating the tab's last pane leaves that pane showing
another open file. Drag a float by its top border to move it or by an edge
to resize it, or use the resize mode (`alt-r`). The tab's
[float layout](#float-layouts) decides where floats go.

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

In `one` the float in front shows where it is on its border:

- `‹ 2/5 ›` at the right of the top, with the names of the floats either
  side when it's wide (`‹ nu ~/src · 2/5 · claude ›`; of two, the other on
  its side: `‹ 1/2 · claude ›`). Click `‹` or a name before it for the
  float before, `›` or a name after it for the next.
- A dot for each float along the bottom, the one in front filled. Click a
  dot for that float (`:float-go N` does the same).
- A dock along the bottom of the tab lists them all by number and name.
  Click a name to bring that float to the front, or press `alt-W` and then
  its number (or move with the arrows and press `enter`). `:float-dock`
  shows or hides the dock in any layout.

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
`core.attention.set(key, { label = ..., reason = ..., buffer = buffer })`
to give it the dot.

## Clipboard

What you copy goes on your system clipboard too, through your terminal
(OSC 52), so it works over `greed ssh` and in tmux with `set-clipboard on`.
Most terminals allow it; some ask first or need it turned on (iTerm2:
"Applications in terminal may access clipboard"). `GREED_CLIPBOARD=off`
keeps copies inside Greed. A program in a Greed terminal that copies the same
way puts the text on Greed's clipboard, so `p` pastes it.

## Mouse

| Mouse | |
|---|---|
| Click | Put the cursor there and focus that pane |
| Drag | Select |
| Wheel | Scroll whatever's under it |
| Double click, triple click | Select the word, the line |
| `shift`-click | Extend the selection to there |
| `alt`-click | Add a cursor there |
| Click a tab in the tab line | Show it |
| Drag a floating view's top border (the title) | Move it |
| Drag a floating view's other edge or a corner | Resize it |
| Drag the line between two panes, or beside a panel | Give one more room |

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
at its own size; `space .` on it offers the same. It shows in the window
and in terminals that show images. A picture in a chat room opens this way
with `enter`, or `open` on `space .`, and `q` or `esc` takes you back to
wherever you opened it from (it's `ctrl-o`, really).

### PDFs

Opening a PDF shows its first page, as wide as the pane. `]` and `[` go to
the next and previous page (with a count, that many), `+` and `-` draw it
bigger and smaller, and `=` as wide as the pane again. `t` switches to the
text of every page, which reads in any terminal and searches with `/`; `t`
again shows the page the cursor is on. `q` or `esc` goes back, as on a
picture.

### Other files

Files Greed can't show open with the program your system opens them with
(`xdg-open`, `open` on macOS, or what the `link-opener` option names):
office documents (Word, Excel, PowerPoint, OpenDocument, Pages, Numbers,
Keynote), e-books, sound and video. Anything else that isn't text, like a
zip file, doesn't open, and Greed says so; `space .` on it offers
`open-outside`.

Your config says how a kind of file opens, by its extension:

```luau
local file = require("@core").file
file.open_with("docx", { "libreoffice" })  -- with this program
file.open_with("zip", "outside")           -- with the system's opener
file.open_with("rtf", "greed")             -- in Greed, as its text
```

Programs and scripts are never handed to another program, whatever the
config says, so opening a file can't run something: a `.exe`, `.app` or
`.desktop` file, or one that starts like a program does whatever it's
called. A script opens as its text.

## The command line

`:` (or `alt-x` in the vscode style) runs any command by name, with
completion.

| Keys | |
|---|---|
| `space ?` | List every command |
| `space h c` | Describe a command |
| `space h k` | What a key does |
| `space h h` | Describe anything the editor is made of: commands, options with their values, events and who listens to them, the plugin API, plugins, modes and editing styles. `enter` in the help window goes to where it's defined |
| `space h i` | Inspect what's under the cursor (a buffer, a shell block or a row of its table, a terminal, a file), or with nothing there the editor itself |
| `history` on `space .` | What was done to anything |
| `f1` | The keys of the mode you're in, in every mode |

`space h i` shows a thing's state, the objects it relates to (`enter` goes
to one, `backspace` or `ctrl-o` comes back, `ctrl-i` goes forward again),
what was done to it, by you or an agent, and what it can do (`enter` runs
that). After a key like `space`, a hint at the bottom right shows what can
follow, with groups of keys named (`w  panes…`). A message on the status
line goes away with the next key.

`:lua CODE` runs a line of Luau with the whole plugin API, and `:= EXPR`
shows what an expression is (`:= #greed.buffers()`).

The short names Vim and Helix users type work too: `:w` `:wa` `:q` `:qa`
`:wq` `:wqa` `:x` `:e` `:b` `:bn` `:bp` `:bc` `:ls` `:sp` `:vs` `:only`
`:tabnew` `:noh` `:rl` `:rla` `:set` `:toggle`, `:colo` (`:colorscheme`)
for `:theme`, `:setf` for `:language`, Neovim's `:checkhealth` for
`:health`, and Helix's long ones like `:write-all` and `:buffer-close`.
Arguments go after a space (`:w notes.md`); only Vim's line commands and
`:b` take one right after the name (`:m0`, `:t$`, `:b#`). A command that
refuses, like `:q` with unsaved changes, says why; an error from a bug in
a plugin also names the plugin, and `:errors` has the details.

Vim's line commands work in every style. A range in front picks the lines
a command works on; without one, it's the lines the selection touches
(`:g` and `:v` take the whole file).

| Command | |
|---|---|
| `:42`, `:$` | Go to line 42, or the last line |
| `:s/regex/text/flags` | Replace on the lines: `g` every match on a line, `i` ignore case, `I` match case, `n` only count, `c` ask about each (`y` yes, `n` no, `a` this and the rest, `l` this and stop, `q` quit); `\1` and `&` put back what matched. Undo puts the cursor back on the first line changed |
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

Plugins others share in git are named in your config, in `init.luau` or a
file you require from it:

```luau
local plugins = require("@git-plugins")
plugins.use("https://github.com/someone/greed-jump")
plugins.use("https://github.com/someone/greed-todo", { ref = "v2", name = "todo" })
```

Naming one only records it, so starting never waits on the network: once
Greed is up, what's missing is fetched in the background into the data
folder (or now, with `:plugins-sync`) and loads like your own, asking for
your approval if it wants capabilities. Each is pinned to a commit in
`plugins.lock` next to your config, so another machine with the same
config and lock file gets the same ones; commit it with your config.
`:plugins-update` (or `:plugins-update NAME`) moves them to the latest of
the branch or tag they follow, asking again if an update wants more.
To stop using one, take its line out of your config and run
`:plugins-sync`: the plugin goes to the trash and its pin goes from the
lock file. Starting Greed never removes plugins on its own.
[Plugins to install](plugins-to-install.md) lists some to try.

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
sessions' sockets).

| Flag | Variable |
|---|---|
| `--profile` | `GREED_PROFILE` |
| `--config-dir` | `GREED_CONFIG_DIR` |
| `--data-dir` | `GREED_DATA_DIR` |
| `--cache-dir` | `GREED_CACHE_DIR` |
| `--state-dir` | `GREED_STATE_DIR` |

A folder's own setting wins over the profile, which wins over the XDG
variables. Sessions' sockets go in `GREED_RUN_DIR` when it's set, for when
a profile's path is too long for a socket (about a hundred characters at
most). Sessions, terminals, shells and agents Greed starts get the same
folders, so `greed ctl` inside one of its terminals finds its session.
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
`:trust` runs it, now and whenever the project opens again. Trusting a
project also lets its language servers start and its files format on
save, which run its code too; Greed asks the first time a file of an
untrusted project opens (see
[Trusting a project](permissions.md#trusting-a-project)). Trusted projects
are listed in `~/.cache/greed/trusted-projects`; take a line out to stop
trusting one.

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
to what was saved takes it away. After the file come the function and
type the cursor is in, like `Server › listen`, in languages with a
grammar; `require("@statusline").remove("symbol")` hides them. On the
right it shows:

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
- agents at work or waiting for you, in sessions and in terminals, like
  `◆ 1 working · 1 waiting for you`
- the cursor's line and column (the character the cursor is drawn on, at
  the end of a selection too), the machine and the session

Two options, both off by default, add color and motion:

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

These highlights are on by default (except `effects-dim`), each with an
option of its own:

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

A plain piece that turns out slow (more than 10 ms to draw) is moved to
the background the same way, with a message saying so: from then on it's
drawn at most once a second and the status line shows what it last made.
A status line of your own (`greed.statusline`) that takes too long is
stopped, and the last one stays up for a second before it's built again.
Typing never waits for either.

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

### Indent guides, colors and TODO comments

Files show a few things that aren't in the text, each with an option to
turn it off:

- `indent-guides`: a thin line at each level of indent, through blank
  lines in a block too (style `ui.indent.guide`).
- `color-swatches`: a square in its color in front of a color like
  `#ff8800`, `#fa0` or `#ff880080`. A three-digit one needs a letter in it,
  so an issue number like `#123` stays plain.
- `todo-comments`: TODO, HACK and XXX picked out in comments in one color
  (`comment.todo`), FIXME and BUG in another (`comment.fixme`), NOTE in a
  third (`comment.note`). Only in comments, so a string saying "TODO"
  stays as it is. `:todo-comments` lists them across the project.

Rulers are off until you name their columns: `:set rulers 80,100` draws a
`┊` at columns 80 and 100 wherever nothing is written there (style
`ui.ruler`). They don't reach the empty rows below the end of the file.

```luau
require("@greed").option.set("rulers", "80,100")
require("@greed").option.set("indent-guides", false)
require("@todo-comments").words.PERF = "comment.note"
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

A theme can come from a plugin too, like
[zenbones](https://github.com/johnae/greed-zenbones). `theme.use` and the
theme you picked last wait for it: the one in use stays until the plugin
adds it, as on the first start, while it's still being fetched.

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
`rounded` gives floats rounded corners in both: drawn smooth in the window,
as `╭╮╰╯` in the terminal. These fields are for the window only:

| Field | |
|---|---|
| `shadow` | Floats with a soft shadow |
| `badge` | The style's background as a small box with rounded corners, like a key cap (motion hints and buttons use it) |
| `hover` | Light up what's under the mouse (buttons, fields, choices, tabs) |
| `checkbox = "empty"` or `"checked"` | A checkbox over the text (todo boxes use it) |
| `checkbox = "choice"` or `"chosen"` | A round button (Markdown choices use it) |
| `font = "prose"` | Text in the proportional font |
| `font = "Monaspace Radon"` | Text in that family, in the grid's cells; the grid's font when it isn't installed |

Naming a family works best with ones made to share a grid, like the
Monaspace families: comments in Radon, which looks handwritten, beside code
in Neon, like this:

```luau
greed.theme.set({ comment = { italic = true, gui = { font = "Monaspace Radon" } } })
```

The terminal keeps the italic and draws the rest as usual.

`#rrggbb` colors go out as they are when the terminal says it shows 24-bit
color (`COLORTERM=truecolor`, as most do), and as the nearest of 256 colors
when it doesn't, like tmux without its `RGB` feature. `GREED_COLORS=truecolor`
or `GREED_COLORS=256` decides for a terminal that says the wrong thing.

### Highlighting and syntax queries

Greed has grammars built in for Rust, Nix, Bash, Python, Go, JavaScript,
TypeScript, C, Luau, JSON, TOML, YAML and Markdown. For C++, C#, Java,
Ruby, Scala, Haskell, OCaml, Julia, HTML, CSS and HCL (Terraform and
OpenTofu, whose language servers `terraform-ls` and `tofu-ls` start when
installed) it downloads the grammar the first time you open a file in that
language, checks it against a checksum Greed knows, and keeps it in
`~/.cache/greed/grammars`.

| | |
|---|---|
| `:health` | Which languages are built in, which download, and which have no grammar |
| `:grammar-fetch ruby` | Download one ahead of time, say before going offline |
| `greed.option.set("grammar-download", false)` | Turn downloading off |

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

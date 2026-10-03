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

`kern commands` lists every command line command, including the ones
plugins add (`kern ls`, `kern new` and `kern bring` are plugins too).

Switching to another session (`space P`, `:session`) moves your terminal
there and leaves the session you were in running. Over `kern ssh` it
reconnects through a new ssh connection, which is close to instant with
ssh connection sharing (`ControlMaster`).

In one of Kern's own terminals, `kern FILE` opens the file in that session
and returns, rather than starting an editor inside the editor, and
`kern ctl` talks to that session. Programs there can tell from
`$KERN_TERMINAL`, which names the session.

Attaching from a second terminal takes the session over from the first. If
a session can't start in the background, `KERN_NO_SESSION=1 kern FILE` runs
the editor directly in the terminal.

A session that quits remembers its projects, their open files and where the
cursor was, and opens them again the next time it starts. It writes this
down when it quits and whenever you save a file, in the cache folder
(`~/.cache/kern/sessions`). Starting with a file keeps that file shown. Turn
it off with `kern.option.set("restore-session", false)`.

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
| `:session NAME` or `:session PATH` | Go to a running session, or to the session for a project (starting it) |
| `:project-close` | Close the shown project |
| `:q` | Close the shown project and leave; on the last one, quit |
| `:qa` | Quit every project |

A recent project or a folder typed into `space P` opens in its own session,
starting it if it isn't running, like `kern FOLDER` from a terminal.
`:project PATH` opens a project in this session instead. `space P` works the
same in the Helix and Vim styles; in edit mode, where space types, pick
`pick-project` from the command palette (`ctrl-P`).

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
kern ssh build-box src/main.rs
```

`kern ssh HOST [--session NAME] [FILE]` shows a session running on another
machine, starting one there if none is running. Files, language servers,
search and agents all run on that machine, and only keys and screen updates
cross the network. If the connection drops or you `:detach`, the session
keeps running, and `kern ssh HOST` comes back to it.

`kern ssh HOST --terminal` does the same and opens a terminal on that
machine in a new tab, for when a shell is what you're after. It runs in the
session, so it's still there after you disconnect. `kern --terminal` does
the same here.

Your config comes along: `kern ssh` copies `~/.config/kern` (your
`init.luau` and plugins) to the other machine first, and a session it
starts there runs that copy, so the editor works the way you set it up.
The other machine's own `~/.config/kern` runs after it and wins, and
`kern ssh` never touches it. Changes you make there, or an agent makes, or
plugins an agent installs, stay on that machine across connections. A
session that was already running keeps the config it started with.
`KERN_SSH_CONFIG=0` leaves your config at home.

To keep a plugin you made over there, bring it home. `kern bring HOST`
lists the plugins in the other machine's own config and data folders, and
`kern bring HOST PLUGIN` copies one into your config's `plugins` folder.
Kern asks you to approve what it uses the next time it starts.

```sh
$ kern bring build-box
build-box has these; kern bring build-box PLUGIN copies one here:
  /home/me/.config/kern/plugins/todo-sync
$ kern bring build-box todo-sync
```

Your login shell on the other machine can be anything (bash, fish,
nushell): `kern ssh` only asks it to start `sh`, and needs a POSIX `sh`
and `tar` there. Where commands over ssh come without `XDG_RUNTIME_DIR`,
a session it starts uses `/run/user/<uid>` like a login would, and so do
the programs in its terminals.

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
| `f` `t` + a character | Select to the next one, or up to it; `F` `T` go back |
| `x` | Select the line |
| `g g` `g e` | Start of the file, start of its last line |
| `G`, `5 G` | The last line, or line 5 |
| `g h` `g l` `g s` | Start and end of the line, first character that isn't a space |
| `m m` | The matching bracket |
| `g w` | Label every word on screen; type a label to jump there |
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
| `u` `U` | Undo, redo |
| `.` | Repeat the last change at the selections, with what it typed (`3 .` with a new count) |
| `esc` | Back to normal mode |

In insert mode, `tab` types a level of indent, `ctrl-w` (or
`alt-backspace`) and `alt-d` delete a word back or forward, `ctrl-u` and
`ctrl-k` delete to the start or end of the line, `ctrl-x` asks for completions, and `ctrl-r` + a
register inserts what it holds.

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
{ indent = 4 })`; the `indent` option is for files in no language.

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

**By syntax**, in languages Kern has a grammar for (`:health` lists them):

| Keys | |
|---|---|
| `m i f` `m a f` | Inside or around the function |
| `m i t` `m a t` | Inside or around the type: a struct, enum, impl or table |
| `m i a` `m a a` | An argument or parameter, around with its comma |
| `m a c` | The comment |
| `m i T` `m a T` | Inside or around the test (Rust, Python, Go, JavaScript and TypeScript) |
| `m a e` | An entry in a table, map or struct |
| `] f` `[ f` | The next or previous function; also `t`, `a` and `c` |
| `alt-o` `alt-i` | Grow the selection to the syntax node around it, or shrink it back |
| `] n` `[ n` | The next or previous node beside it (Helix has these on `alt-n` `alt-p`, which are pane keys here) |
| `alt-a` `alt-I` | Every node beside it, or every node inside it |
| `alt-b` `alt-e` | The start or end of the node around it |
| `space s` | Jump to a function or type in the file |

In Vim's style the same objects are `if` `af`, `ia` `aa` and `ic` `ac`, as in
`daf` or `cia`, and the next/last, indent and number objects are `in(`
`il(`, `ii` `ai` and `id` `ad`, as in `cin(` or `dii`.

**Folding**

| Keys | |
|---|---|
| `z a` | Fold the block the cursor is in under its first line, or unfold it |
| `z C` `z o` | Fold it, or unfold the folds the cursor is in (`z c` in the Vim style) |
| `z R` | Unfold everything |

A block is the smallest function, body, table or similar around the
cursor's line, from the language's grammar. In a language without one,
it's the lines indented under the nearest line indented less, and in
Markdown it's the section under a heading. Vim's style has the same keys,
and also `z M` to fold every outermost block, `z f` + a motion to fold
those lines, `z j` `z k` to go to the next or previous block, and `z d`
`z E` to unfold.

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
| `*` | Search for the selected text, exactly as written; a whole word only matches whole words |
| `alt-*` | The same, also inside longer words |
| `space /` | Search the whole project as you type |

Patterns are regexes; ones written in lowercase ignore case.

In the project search, `enter` opens a match and `ctrl-e` puts what was
found in a panel: a multibuffer, with each matching line under its file's
name and beside its line number. Edit those lines with any of the editing
keys above (`s` to select the matches, then `c` to change them all) and
the files change as you type; `:w` saves them, `enter` goes to the line and
`q` closes the panel. A file that changed on disk since the search is left
alone and reported. `:grep PATTERN` fills the panel directly.

## Files and buffers

| Keys | |
|---|---|
| `space f` | Find a file in the project |
| `space F` | Find a file under the folder Kern was started in |
| `space '` | Open the last picker again |
| `space b` | Switch to an open file |
| `space j` | Pick a place from the jumplist |
| `space y` `space p` `space R` | Copy, paste and replace, as in Helix (copies always go to the clipboard here) |
| `space e` | File tree in a side panel |
| `:w` `:w PATH` | Save, or save as |
| `:e PATH` | Open a file |
| `ctrl-s` | Save |
| `:bc` (`:bd`) | Close the file; the one opened before it takes its place. `:bc!` closes it with unsaved changes |
| `:bco` | Close every other file |
| `:close` | Close the pane (the file stays open), like `alt-p x` |
| `:reload` | Load the file again from disk |
| `:stalls` | The times plugin code held the editor up, with the plugin and what it was doing |
| `:secret-set NAME` | Keep a secret, like an API key, in the system keyring (or Kern's own secrets file where there's none); what you type shows as dots |

Closing a terminal's buffer ends its program.

When a file changes on disk, from another program or an agent, its buffer
loads the change as an edit you can undo with `u`. A buffer with unsaved
changes is left alone and Kern tells you; `:reload` loads the file into it
anyway. `:set auto-reload false` stops loading changes by itself.

## Language servers

Kern knows the usual languages and their servers and starts a server when a
file needs one and it's installed. `:health` shows each language's server
and whether it was found.

| Keys | |
|---|---|
| `space k` | What's under the cursor, with any problems there |
| `g d` | Go to the definition |
| `g D` `g y` `g i` | Go to the declaration, the type's definition, an implementation |
| `g r` | Pick a place it's used, with a preview |
| `space H` | Select every place in this file it's used (Helix's space h, which is help here) |
| `space S` | Pick a symbol anywhere in the project |
| `space r` | Rename it everywhere it's used |
| `space a` | Pick a fix or refactor for the cursor or selection |
| `space d` | Pick a problem in this file |
| `space D` | Pick a problem in any file the server checked, open or not |
| `] d` `[ d` | Next and previous problem; `] D` `[ D` the last and first |

In the `g r` and `space D` lists, `ctrl-e` puts the places shown in a panel
like the project search's: each reference with a line around it, or each
problem's line with its message beside the file name. Edit them there the
same way.

A rename or code action that changes other files opens them without showing
them and leaves them unsaved, so you can look the change over (`space b`)
and undo it before saving.

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
while you type, leaving `ctrl-space`. In Vim's style, `ctrl-n` and `ctrl-p`
in insert mode complete from the words in open files.

Typing `(` or `,` in a call shows what the function takes, above the
cursor, with the parameter you're on picked out. It follows along as you
type and closes when the call does or you leave insert mode. To ask for it
with a key, bind `signature-help` in insert mode, e.g.
`kern.keymap.bind("insert", { ["ctrl-k"] = "signature-help" })`.

## Version control

In a jj or git repository, lines added (`+`), changed (`~`) and removed
(`-`) since the last commit get a sign beside them. With jj that's against
the working copy's parent, so the signs show what your current change does.

| Keys | |
|---|---|
| `] g` `[ g` | Next and previous change; `] G` `[ G` the last and first |
| `space g r` | Put the change under the cursor back the way it was |
| `space g b` | Who last changed this line, and when |
| `space g g` | Pick a file changed since the last commit |
| `space g s` (`:changes`) | Every change in the project, in one buffer |

`:set vcs-signs false` hides the signs.

`space g s` shows each change since the last commit, in every file, with a
couple of lines around it: added lines in green, and removed ones in red
where they were, under each file's name. It's a multibuffer like the
project search's results, so you can edit the changes there and `:w`
saves the files; `space g r` on a change puts it back, and `enter` goes to
it in its file. New files show whole, and deleted ones are left out.

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

For Anthropic, give Kern your key with `:secret-set anthropic` (it goes in
the system keyring), or set `ANTHROPIC_API_KEY`. `:models` shows each role,
its model and whether its key is found.

Change any of it in your `init.luau`, with OpenAI, Ollama or any server
that speaks OpenAI's chat completions API:

```luau
local models = require("@models")
models.roles.fast = { provider = "ollama", model = "qwen2.5-coder" }
models.roles.reasoning = { provider = "openai", model = "gpt-5" }
models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", secret = "work" }
models.roles.review = { provider = "work", model = "reviewer-1" }
```

A provider with a `secret` reads its key with `:secret-set NAME`, or from
`KERN_SECRET_NAME`.

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
| `space i p` | Pin the selection, or the whole file when nothing is selected |
| `space i i` | Show what's pinned, one item a line with its size in tokens; delete a line (`x d`) to drop it |
| `:context-add-problems` | Pin this file's problems from the language server |
| `:context-add-diff` | Pin the changes in progress |
| `:context-clear` | Drop everything |

Items are read fresh each time they're sent: a pinned selection follows the
text as you edit, and the diff is the diff as it is now. The assist
commands send the context with each question, and agents read it with the
`context_get` tool. Each project keeps its own, across restarts.

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
the brackets and the markup below as written.

```luau
require("@kern").option.set("notes-folder", "~/Documents/notes")
```

### How notes look

On every line but the cursor's, a note's markup shows as symbols: todo
boxes as ☐ and ☑ (done ones dimmed and struck through), headings as a
symbol for their level, list dashes as bullets, and `due:2026-10-03` as
📅 3 Oct, in red once it's past. The file stays plain Markdown; move the
cursor onto a line to edit what's really there. Click a box to tick it, or
a heading's symbol to fold its section.

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
require("@kern").theme.set({ ["notes.tag"] = { fg = "magenta" } })
```

A rule's `pattern` is a Luau pattern; with `show` the match is replaced by
that text, and with `action` (a command name) clicking it or pressing
`enter` on it runs the command. The styles notes use are `notes.todo`,
`notes.done`, `notes.done.box`, `notes.heading`, `notes.bullet`,
`notes.due` and `notes.overdue`.

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
| `ctrl-\`, `esc esc` | Stop typing into the program, to move around its output; one `esc` still goes to the program |
| `ctrl-space` | The same, then `space`: `ctrl-space f` finds a file from inside a terminal |
| `alt-p` and the other `alt` pane keys | Work as in any pane: `alt-p x` closes the terminal's pane |
| `f1` | The keys that work while typing into it |
| `i`, `a`, `enter` | Type into it again |
| `p` | Paste the latest copy into the program |
| `g x`, `ctrl-click` | Open the link under the cursor (or the mouse) |
| `:terminal-close` | End the program and close the terminal |

Out of the terminal, its output is text like any other: select it, search
it, copy it. Lines that scroll off the top stay above the screen, up to
`terminal-scrollback` lines (10000). When the program ends well its
terminal closes; when it fails, the output stays with how it ended, so you
can read what went wrong. A terminal keeps running while you look at other
files, and while you're detached. `:set terminal-shell "fish -l"` changes
what new terminals run.

Programs that ask for the kitty keyboard protocol (Helix, Neovim, fish,
recent shells) get it, so they can tell `tab` from `ctrl-i` or `enter` from
`shift-enter`. For those keys to reach Kern in the first place your own
terminal needs the protocol too (kitty, WezTerm, foot, Ghostty, Alacritty
and iTerm2 have it); Kern asks for it when it starts. `KERN_KEYS=legacy`
turns that off.

Links programs print (as `ls --hyperlink` and `gcc` do) are underlined, and
URLs written in the output open too. They open with `xdg-open` (`open` on
macOS), or whatever `:set link-opener firefox` names.

## Panes and tabs

Split the screen between files and terminals, the way a terminal
multiplexer does, and keep tabs of layouts. Everything stays running in the
session, so after `:detach` and `kern attach` (or over `kern ssh`) the
panes, tabs and terminals are where you left them.

| Keys | |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | Move to the pane on that side (and on to the next tab) |
| `alt-n` | A terminal in a new pane |
| `alt-f` | The tab's floating terminal, shown and hidden |
| `alt-=` `alt--` | More room for the pane (or floating view), or less |
| `alt-[` `alt-]`, `alt-1`... | Tabs |
| `alt-p`, `alt-t` | The pane and tab modes, for everything else |
| `alt-r` | The resize mode: `h j k l` grow the pane or floating view toward that side, `H J K L` shrink it, the arrows move a floating view |
| `ctrl-w v`, `ctrl-w s`, `ctrl-w q` | Split and close, as in Vim and Helix; `ctrl-w H J K L` swap with the pane on that side, `ctrl-w f` the file under the cursor in a split, `ctrl-w n s` an empty one |

The `alt` keys work everywhere, including inside terminals. Moving to a
terminal pane types into it; moving to a file goes back to normal mode.
Entering the pane or tab mode shows its keys at the bottom. All the keys,
and how to change them, are in [Keys](keys.md#panes-tabs-and-terminals).

To act on a pane without moving to it first, `alt-p g` puts a number over
each pane; type one to go there, and you're still in the pane mode, so
`alt-p g 3 f` zooms the third pane and `alt-p g 3 x` closes it. `ctrl-w g`
and `space w g` label them too.

Floating views belong to the tab they opened in: switching tabs hides them
and closing the tab closes them. `alt-f` shows the tab's floating terminal,
and `alt-p W` opens another. `alt-p F` takes the pane you're in out to
float over the tab, or puts a floating view back in as a pane. `alt-p z`
hides the tab's floats and shows them again (terminals keep running),
`alt-p T` lays them out side by side and `alt-p C` stacks them in a
cascade. Otherwise they stay where you put them; drag one by its top
border to move it, or use the resize mode (`alt-r`).

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
which at the bottom. A tab's panes keep an order, and that's what you change:
`alt-m` swaps the pane into main, `alt-p o` moves them all one place
along, and `alt-p [` and `]` give main less room or more. Resizing a pane
by hand switches the tab to `manual`, keeping the shape it had.

`:layout-save NAME` saves the tab as it is: its panes, their sizes, and what
each shows, a file (relative to the project) or a terminal and what it runs.
It goes in the project, in `.kern/layouts/`, so it can be shared with the
rest of the repository; `:layout-save-mine NAME` keeps it in your config,
for any project. `:layout-open` picks one and opens it as a new tab. A
project can open one by itself from its `.kern/init.luau`:

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

## Clipboard

What you copy goes on your system clipboard too, through your terminal
(OSC 52), so it works over `kern ssh` and in tmux with `set-clipboard on`.
Most terminals allow it; some ask first or need it turned on (iTerm2:
"Applications in terminal may access clipboard"). `KERN_CLIPBOARD=off`
keeps copies inside Kern. A program in a Kern terminal that copies the same
way puts the text on Kern's clipboard, so `p` pastes it.

## Mouse

A click puts the cursor where you click and focuses that pane, dragging
selects, and the wheel scrolls whatever's under it. A double click selects
the word, a triple click the line, `shift`-click extends the selection to
where you click and `alt`-click adds a cursor there. Clicking a tab in the
tab line shows it. Drag a floating view by its top border (where the title
is) to move it, or by another edge or a corner to resize it.

Clicking a button (a proposal's accept and reject, a todo's box) presses
it. So does `enter` in normal mode with the cursor on it; where several
buttons share a spot, `enter` lists them to pick from.

In a terminal, a program that asks for the mouse (vim, htop, less with
`--mouse`) gets it. Otherwise the wheel scrolls back through the output,
which stops typing into the program, and scrolling back down to the bottom
types into it again; in a full screen program the wheel sends arrow keys. A
click types into the program, and a drag selects output to copy with `y`.

Most terminals still select text their own way while you hold shift.
`KERN_MOUSE=off` leaves the mouse to your terminal.

## Images

Kern shows images in terminals that speak the kitty graphics protocol:
kitty, Ghostty, WezTerm and Konsole. It finds out from the variables those
terminals set; `KERN_IMAGES=kitty` turns images on in another that speaks
the protocol, and `KERN_IMAGES=none` turns them off. Elsewhere, the text
under an image shows instead.

Programs in Kern's terminals can show images too, with the same kitty
protocol or iTerm2's: `kitten icat picture.png`, `imgcat`, chafa's and
yazi's previews. They scroll with the output, and text written over them
takes their place, as in any terminal.

## The command line

`:` (or `alt-x` in edit mode) runs any command by name, with completion.
`space ?` lists every command, `space h c` describes one and `space h k`
tells you what a key does. After a key like `space`, a hint shows what can
follow, and `f1` shows the keys of the mode you're in, in every mode. A
message on the status line goes away with the next key.

Vim's line commands work in every style. A range in front picks the lines
a command works on; without one, it's the lines the selection touches.

| Command | |
|---|---|
| `:42`, `:$` | Go to line 42, or the last line |
| `:s/regex/text/flags` | Replace on the lines: `g` every match on a line, `i` ignore case, `n` only count; `\1` and `&` put back what matched |
| `:g/regex/command`, `:v/regex/command` | Run a command on each line that matches, or doesn't; with no command, select those lines |
| `:d` `:y` | Delete or copy the lines |
| `:m 0` `:t $` | Move or copy the lines below a line (`0` is the top) |
| `:norm keys` | Type the keys in normal mode on each line |
| `:j` `:>` `:<` | Join, indent or dedent the lines |

Ranges are line numbers, `.` (the cursor's line), `$` (the last),
`/regex/` (the next line matching), `'<` and `'>` (the selection's first
and last line) and `%` (every line), with `+n` or `-n` after any of them:
`:%s/old/new/g`, `:.,+3d`, `:/^fn/,$norm A;`. Patterns are regexes, as in
search. In Vim's style, `:` in visual mode starts with `'<,'>` and `3 :`
with `.,.+2`.

## Configuration

Your config is `~/.config/kern/init.luau`, plain Luau with the full plugin
API. Your own plugins go in `~/.config/kern/plugins/NAME/`.

Saving your config, in Kern or anywhere else, runs it again within a
second: what it registered (commands, keys, theme entries, event handlers)
is taken away and set up anew, and the status line says "config reloaded"
or what went wrong. Options it set keep their values until it sets them
again. `:config-reload` does the same by hand.

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

### The status line

The status line shows the mode, the tab, the file and whether a macro is
recording on the left, and problems, the cursor's place, the machine and
the session on the right. Two options make it livelier, both off unless you
turn them on:

```luau
local option = require("@kern").option
-- The mode, tab, machine and session as pills in their theme colors, with
-- rounded ends (they need a Nerd Font; "none" makes them square)
option.set("statusline-pills", true)
option.set("statusline-caps", "round")
-- A wave of light through the letters of the tab or the file when you go
-- to another, and a glow from the middle of the mode when it changes
option.set("effects", true)
```

The wave's letters glow towards the theme's `ui.glow` color: brighter text
in a dark theme, the accent in a light one. Effects need a theme with
`#rrggbb` colors, so the default 16-color theme has none.

Add pieces of your own, or take some away:

```luau
local statusline = require("@statusline")
statusline.add("right", "clock", function()
	return os.date("%H:%M")
end)
-- A pill in a theme style
statusline.add("left", "branch", function()
	return { text = "main", style = "ui.statusline.tab" }
end)
statusline.remove("host")
```

A piece gets the main view, its buffer, the mode and the message, and
returns text, a pill (`{ text, style }`), a list of pills shown joined, or
nil to show nothing. The pills' colors are the theme's
`ui.statusline.mode`, `.tab`, `.tab.number`, `.host` and `.session`.

A piece is drawn with every frame, so it has to be quick and can't run
programs. For anything that takes time, like a repository's state in a big
monorepo, add an async piece: its `refresh` runs in the background and can
run programs, and the status line shows what it last found, never waiting
for it.

```luau
statusline.add_async("right", "change", {
	refresh = function()
		local done = require("@kern").process.run({
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
one the same way. The theme you pick is remembered for next time.

Kern comes with `default` (your terminal's 16 colors, so it follows your
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
-- colors for keywords, functions, strings, types, constants and operators
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

`kern.theme.set` changes single names on top of whichever theme is in use,
and those changes stay when you switch themes. Each changes only the fields
it gives: `kern.theme.set({ comment = { italic = false } })` keeps the
theme's comment color. A theme's own `styles` work the same way on what it
inherits. Names fall back to their parent, so `keyword.control` uses
`keyword` unless it has its own entry; [Highlighting](highlighting.md) lists
them.

`#rrggbb` colors go out as they are when the terminal says it shows 24-bit
color (`COLORTERM=truecolor`, as most do), and as the nearest of 256 colors
when it doesn't, like tmux without its `RGB` feature. `KERN_COLORS=truecolor`
or `KERN_COLORS=256` decides for a terminal that says the wrong thing.

### Highlighting and syntax queries

Kern has grammars built in for Rust, Nix, Bash, Python, Go, JavaScript,
TypeScript, C, Luau, JSON, TOML, YAML and Markdown. For C++, C#, Java,
Ruby, Scala, Haskell, OCaml, Julia, HTML and CSS it downloads the grammar
the first time you open a file in that language (with `curl`), checks it
against a checksum Kern knows, and keeps it in `~/.cache/kern/grammars`.
`:health` shows which languages are built in, which download, and which
have no grammar. `:grammar-fetch ruby` downloads one ahead of time, say
before going offline, and `kern.option.set("grammar-download", false)`
turns downloading off.

What gets highlighted, and what counts as a function for `m i f`, comes
from tree-sitter queries: files named `queries/LANGUAGE/KIND.scm`, where
KIND is `highlights`, `injections` (languages inside others, like the code
blocks in Markdown, which are highlighted in their own language),
`textobjects`, `folds` (the blocks `z a` folds, captured as `@fold`) or
`indents` (nodes whose lines go a level in, `@indent`, and closing tokens
that line up with their block's first line, `@outdent`).
Kern reads them from every plugin and from `~/.config/kern/queries`, so a
file there replaces Kern's own. To add to it instead, start the file with
`; extends`:

```scheme
; extends
; ~/.config/kern/queries/rust/highlights.scm: TODO in comments stands out
((line_comment) @comment.todo (#match? @comment.todo "TODO"))
```

[Highlighting](highlighting.md) lists the names highlights queries use
and the theme styles.

A query with a mistake in it says so when Kern starts, and the one before
it stays in use. `require("@languages").load_queries()` reads the files
again after you change them.

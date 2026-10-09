# The shell

`:shell` opens a shell in a buffer. You type a command at the prompt at the
bottom, `enter` runs it, and it becomes a block above the prompt: the
command, what it printed, and how it ended. Blocks stay, so you can
search them, fold them, copy from them, run them again and send their
output to the next command. It's meant for the commands you run while
editing, and for output you want to keep working with; a terminal pane is
still the place for a long interactive session.

```text
❯ 1 cargo test -q                         ✗ exit 101 · 4.1s
error[E0308]: mismatched types
 --> src/main.rs:12:5
❯ 2 git status --short                    ✓ 0.02s
 M src/main.rs
⎇ main ~/s/app ❯ |
```

The prompt shows the shell's folder, every folder but the last cut to its
first letter, and before it what [the prompt](#the-prompt) knows, like the
git branch. `space o s` switches to the shell of this project, or opens
one; with several, or from the only one, it lists them with a new one to
open. `:shell NAME` opens another. Each shell has its own folder and
variables, and a project can have several. Shells and their blocks last
until you close them or the session ends, and what you type in one is
nothing to save: `:q` doesn't ask about it. A new shell says to type `help`, which
lists what the shell runs itself, what a line can hold, which shell runs
the rest, and the keys in the style you use; `help TOPIC` shows one part.

## The prompt

Before the folder, the prompt shows the branch of the repository the shell
is in (with jj, the nearest bookmark and the change), and the kubernetes
context and namespace `kubectl` would use. The context comes from
kubectl's config file, the ones `KUBECONFIG` names or `~/.kube/config`,
read without running kubectl, so it's there at once and costs nothing.
They're worked out again after every command, so a `cd`, a checkout or
`kubectl config use-context` shows on the next prompt.

```text
⎇ main ⎈ prod-eu:payments ~/s/infra ❯ kubectl get pods
```

A context matching a pattern in `shell-production-contexts` (`prod` by
default; several go with spaces between them, as Luau patterns, like
`:set shell-production-contexts "prod ^live%-"`) shows in red, and so
does the `❯`, so a command about to run against production looks like it.
Plugins add pieces of their own, like a cloud profile; `help prompt` lists
them.

## Blocks

A block's command is the line it starts on, with `❯` before it (`◆` for
one an agent ran) and its number, the `3` of `$3`. After the command comes
how it went: `◐` while it runs with how long so far, then `✓`, `✗ exit 1`,
`■ INT` when it was stopped, `↗` when it was handed to a terminal, or `?`
for a question to a model that brought no command back, how
long it took, where `cd` went and which variables it set. A block that went
quiet while it could be reading a line says it may be waiting for input.

Output that's JSON or a table is kept as a value on the block too, and
the status says so (`JSON · 3 items`, `table · 12 rows`); see [Filtering
and tables](#filtering-and-tables). Places in files the output names, like
`src/main.rs:12:5`, are links: `] e` and `[ e` go to them, and `enter` on
one opens the file there, taking relative paths from the folder the block
ran in.

A block shows at most `shell-max-lines` (5000) lines of its output, the
first half and the latest half, saying how many it leaves out between them;
`space v` opens all of it in a buffer of its own. Past `shell-max-record`
(8 MB) the whole output goes to a file in the cache folder, which `space v`
opens.

A prompt of more than `shell-confirm-lines` (5) lines, as pasting a
transcript or a file can leave there, asks `y/n` before it runs as one
command.

Undo at the prompt takes back what you typed since the last command ran,
while output keeps streaming in above it; it never reaches back into a
command that ran.

## Keys

In Helix and Vim you type at the prompt in insert mode. `enter` on a block,
the keys for moving between blocks and files, `g o` and the `space` keys
work in normal mode; `up`, `down`, `alt-enter` and `tab` work while typing.

| Keys | |
|---|---|
| `enter` | At the prompt, run what's there. On a block, put its command at the prompt to change; on a file and line it names, open it there |
| `alt-enter` | Another line at the prompt |
| `up` `down` | At the prompt: the commands typed before that start with what's typed |
| `ctrl-r` | Pick a command typed before, in any shell |
| `tab` | Complete a program, its arguments and flags, a file or folder, a variable, `$3`, `buf:` or `@sel`: the only match or what they all start with at once, else a menu, which `tab` again goes through |
| `ctrl-c` | Interrupt the running block |
| `ctrl-t` | Type into the running block's program, in a terminal in the shell's place |
| `[ p` `] p` | The block before or after the cursor |
| `g o` | Select the block's output |
| `] e` `[ e` | The next or previous file and line the output names |
| `space r` `space R` | Run the block again as it ran, or in the shell's folder now |
| `space y` `space Y` | Copy the block's output, or its command |
| `space x` | Stop the running block for good |
| `space v` | Open the block's whole output in a buffer |
| `space c` | Take the finished blocks away |
| `/` | On a block's output, keep the lines (or a table's rows) with what you type; elsewhere, search |
| `space s` `space S` | Sort a table by the column under the cursor; show a block as it came |

In the vscode style you're always typing, so the keys that need normal
mode have others: `ctrl-c` copies when something is selected and
interrupts otherwise, `ctrl-up` and `ctrl-down` go between blocks, `f8`
and `shift-f8` between the files and lines the output names, `ctrl-f`
filters a block, and the `space` keys above are `ctrl-space` ones.
`space .` (`alt-.` in the vscode style) on a block lists what you can do
with it.

## What runs your commands

The shell runs a few commands itself:

| Command | |
|---|---|
| `cd [DIR]` | Change the shell's folder: a path, `-` for the one before, nothing for home |
| `export NAME=VALUE ...` | Set variables for the commands after |
| `unset NAME ...` | Leave variables out of the commands after |
| `env` | List the variables this shell sets or leaves out |
| `history` | The commands typed before |
| `clear` | Take the finished blocks away |
| `open PATH ...` | Open files, or `buf:NAME` buffers, in the editor |
| `help [TOPIC]` | What works here, and the keys in the style you use; a topic for one part |

What `open` opens comes up in your style's own mode, to read and move
around in, not typing as at the prompt.

Every other line goes to your shell, so `ls` and `ls | head` behave the
same: your `$SHELL` when it's a POSIX shell (sh, bash, zsh, dash, ksh and
the like), fish or nu, and `sh` otherwise; `:set shell-fallback bash` picks
one. `cd` and `export` there carry over to the commands after, as they
would in a terminal. If `shell-fallback` names a shell of another kind, the
line still runs in it, and its block says `cd` and `export` in it don't
carry over. Your shell's startup files aren't read, so aliases and
functions aren't there unless you `:set shell-fallback-rc true`.

Programs get `PAGER=cat` and `GIT_PAGER=cat`, so their output comes back as
text, `GREED_BIN`, the greed program running the editor, `GREED_SESSION`
and `GREED_BLOCK`, the block they run in.

## Editing files from a command

A program that opens an editor, like `git commit`, `jj describe`, `kubectl
edit` or `crontab -e`, opens the file in Greed, in the pane the command
ran from. `:wq` (or `:q` once it's saved) hands it back and the shell shows
there again; `:cq` stops the program with an error, so `git commit` gives
up. `EDITOR`, `VISUAL`, `GIT_EDITOR`, `JJ_EDITOR` and `KUBE_EDITOR` are
`greed edit --wait`, so this wins over an editor set in git's or jj's
config. An agent's commands keep your own editor, and `:set shell-editor
false` turns it off; `export EDITOR=vim` in a shell picks another for that
shell.

`greed edit FILE...` works from any terminal too: it opens the files in
the running editor, and with `--wait` returns once each is done with.

## Terminals

Commands you type run in a pseudo terminal of their own, so they see a
terminal: they print their colors and progress bars, and their output and
errors come in order. A line longer than the screen stays one line in the
buffer, so each client shows it wrapped at its own width.

A program that wants the whole terminal (an editor, a pager, `htop`,
`ssh`, `sudo` asking for a password) takes over the shell's pane as a
terminal, and the shell comes back when it's done with the screen or
exits, its block marked `↗`. `ctrl-t` does the same for any running block,
to answer a question it's waiting on. Start a line with `!` to run it in a
terminal from the start.

## Data from the editor

A line can start with something from the editor, piped into the command:

| | |
|---|---|
| `$3 \| sort` | What block 3 printed |
| `buf:NAME \| wc -l` | The text of a buffer: one `> buf:` made, an open file at that path, or an open file of that name |
| `@sel \| jq .` | The selection in the file you're in, each range on a line of its own |
| `@file \| head` | The whole file you're in, unsaved changes included |

And end with where its output goes:

| | |
|---|---|
| `... > buf:NAME` | Into a buffer, made if there's none, emptied first |
| `... >> buf:NAME` | Added to the end of a buffer |

Errors still show in the block. One of these alone passes it on: `$3`
shows block 3's output again, `$3 > buf:keep` keeps it in a buffer, and
`open buf:keep` shows that buffer. Such lines run through a pipe rather
than a terminal, so a `> buf:` gets only what the program printed, and
can't be combined with `!`.

## Filtering and tables

Most output is text, and stays text. On top of it the shell keeps what it
can read out of it, and every layer below works on what's under it.

### Filtering a block

`/` on a block's output keeps the lines with what you type in them, as you
type it; several words keep the lines with all of them, in any case, and
a filter that starts with `/` is a regex (`/^error|warn`). `enter` keeps
the filter; `esc`, while typing it or after in normal mode on the block,
shows every line again, and `space S` also undoes a sort. The block
shows the lines kept and the status says so (`2 of 340 lines · / error`),
while its record keeps them all, so `$3`, `space y` and `space v` give the
whole output. On a block's command or at the prompt, `/` searches as
usual.

### Tables

Output in columns under a header, as `kubectl get`, `docker ps`, `ps aux`
and `df` print it, is also kept as a table on the block, and the status
says so (`table · 12 rows`). So is `ls -l`'s output. The shell looks for a
header in capitals with the columns lined up under it in every row, and
when it isn't sure, the output is text: prose is never taken for a table.

In a table, `/` keeps rows: a word like `STATUS=Running` or `NAME~api`
looks in one column, `RESTARTS>0` and `AGE<1h` compare numbers, and other
words look in every cell. `space s` sorts the rows by the column under
the cursor, again from the greatest, and a third time as they came.

```text
❯ 3 kubectl get pods                   ✓ 0.41s · 2 of 5 rows · / STATUS=Running api
NAME                  READY   STATUS    RESTARTS        AGE
api-7d9f8b6c5-2xkqz   1/1     Running   0               3d16h
api-7d9f8b6c5-9wlmn   1/1     Running   3 (3d16h ago)   5d2h
```

A table also goes to the next command through `$`, where the shell itself
runs these on it, each making a new table, as in `$3 | where STATUS =
Running`:

| | |
|---|---|
| `where COL OP VALUE` | The rows passing a test: = != ~ !~ < > <= >= |
| `select COL,...` | Only those columns, in that order |
| `sort COL [-r]` | Sorted by a column, from the greatest with -r |

Column names don't mind case, and `container_id` names `CONTAINER ID`.
Numbers are compared as numbers, with sizes (`512Mi`, `1.5G`, `250m` of a
CPU), percentages and ages (`45s`, `12m`, `3d16h`) read as what they
mean, so `$3 | where AGE < 1h` and `$3 | sort RESTARTS` do what they
say; kubectl's `3 (3d16h ago)` restarts count as 3. They chain, and a
program after them reads the table as text:

```text
❯ $1 | where STATUS != Running | select NAME,STATUS,AGE
❯ $1 | sort RESTARTS -r | where RESTARTS > 0 | wc -l
❯ $1 | where IMAGE ~ postgres > buf:databases
```

`sort` without a column is the `sort` program, as always. The stages go
first, right after `$3 |`: one after a program, as in `$3 | grep api |
where ...`, says so instead of running, and so does one on output that
isn't a table, saying what makes one.

### JSON

Output that's JSON is kept as a value on the block (`JSON · 3 items`),
and an array of objects is a table too, with a column for each key, so
`/` and `space s` show it lined up in columns, and `$3 | where` works on
it. Many tools print JSON when asked, which is the surest way to a table:
`kubectl get pods -o json` gives every field, where its columns give a
few. The shell never runs your command again with other flags; it reads
what it printed.

The stages work on an object too: its fields are the columns of one row,
so `$3 | select name` gives its name, and when one of its fields holds an
array of objects, like kubectl's `items`, the columns it doesn't have are
that array's, so `$3 | where phase = Failed` looks through the items.
`get` picks a field:

| | |
|---|---|
| `get PATH` | A field of JSON, like items or items.0.name (arrays count from 0) |

`$3 | get items` is the items' table, `$3 | get items.0.name` the first
one's name, `$3 | get metadata.labels` an object, printed as JSON, and
`$3 | get items.name` each item's name.

### Saying what it is

When the shell finds no table, say how to read the output, as in `$3 |
from csv`:

| | |
|---|---|
| `columns [-H]` | Text lined up in columns, under a header or with -H none |
| `from csv\|tsv\|json` | CSV, tab separated values, or JSON or JSON lines |
| `split SEP` | Each line cut at SEP into columns 1, 2, ... |
| `lines` | A row for each line, in a column `line` |

`columns -H` names the columns `1`, `2`, ..., as `split` does, and `from
json` reads JSON lines too, an object on each line, as many logs are.

They make tables like any other, for `where`, `select` and `sort`:
`$3 | split : | where 7 ~ zsh | select 1`. A buffer or the selection
works too: `buf:data.csv | from csv | where total > 100`. A program in a
terminal prints tabs as spaces, so tab separated output reads best from a
file, with `buf:`.

### Parsers from plugins

A plugin can read its commands' output as tables, ahead of the shell's
own look ([Writing plugins](plugins.md#the-shell) has how). And when
[jc](https://github.com/kellyjonbrazil/jc) is installed, output the shell
found no table in, from a command jc knows (`ifconfig`, `dig`, `mount`,
`uptime` and many more), gets jc's reading of it.

## Asking for a command

A line that starts with `?` asks a model for a command instead of running
anything: `? the ten biggest files under here`. So does a line ending in
`?` that reads as a question (three words or more, so `ls a?` stays a
glob), and one with a `?` between what you've typed so far and the
question, `ls | where ? only files over 1 MB`. The model gets the shell's
folder, which shell runs your lines, and your last few commands with how
they ended and the end of their output, marked as text someone else
wrote. Its command goes to the prompt for you to read, change and run.

It asks the model playing `shell-ask-role` (`fast`); `:models` shows and
sets them up. Without one, or without its key, a block marked `?` (nothing
ran, so it has no exit code) says why, naming
the variable that sets the key, like `ANTHROPIC_API_KEY`.

## History and completion

The commands you type at every shell are kept in your data folder
(`~/.local/share/greed/shell/history.jsonl`), the last
`shell-history-size` (5000) of them, so `up` and `ctrl-r` find them in
every session. An agent's commands aren't kept.

`tab` completes what fits where the cursor is, as a shell does: the only
match goes in at once, and with several, what they all start with. When
that's all there is, `tab` shows the menu, and `tab` again puts each item
in place in turn (`shift-tab` goes back); `enter` or typing on keeps it.
Command names that start with what you typed come first, then those
holding it, then looser matches, so `hist` offers `history` first.

A menu also opens by itself once typing pauses
([`completion-delay`](using.md#language-servers), 150 ms). It's a hint
until you move into it with `tab`: `enter` runs the line as typed, and
`up` and `down` go through the history. So typing `ls -la`, pausing and
pressing `enter` runs `ls -la`. `:set completion-enter first` makes `enter`
take the menu's first item instead.

What the shell itself knows is marked `greed` in the menu, with what it
does beside it:

- A command's first word: the builtins and the programs on your `PATH`;
  after `$3 |`, the stages too.
- A builtin's arguments: folders after `cd`, files and buffers after
  `open`, variables after `export` and `unset`, topics after `help`.
- A stage's: the columns of the table it reads (`$3 | where `), then the
  comparisons, then the values in that column; `from`'s formats.
- `$` for variables and earlier blocks, `buf:` for buffers, and `@sel`
  and `@file`.

A program's arguments come from what knows them, the first that answers:
a completer a plugin added for the program; the program itself when it's
built with Cobra (kubectl, helm, gh, docker, flux, argocd, and any other
with Cobra's completion inside); fish's completions when fish is
installed; carapace's when it is; and for a flag, the program's man page,
read from the file. Last, when you press `tab` on a flag, what the
program prints for `--help` (and for a subcommand its help lists, that
one's). Files and folders when none of them knows, or the program says
files fit.

```text
~/s/app ❯ kubectl get po
  pods                  Pod
  podtemplates          PodTemplate
  poddisruptionbudgets  PodDisruptionBudget
```

The programs asked run in the background, in the shell's folder with its
variables, for at most `shell-completion-timeout` (2000) milliseconds;
typing on stops one that's no longer needed, and an answer is kept a few
seconds, so typing more of a word narrows it without asking again. Your
program runs only for `--help`: a Cobra program is asked with its
`__complete` command, the way every shell asks it, and whether a program
is Cobra's is found by looking inside it. `:set shell-help-completion
never` stops `--help` from running at all, and `shell-help-never` lists
programs it never runs for (`reboot`, `shutdown` and the like).
`shell-completion-sources` (`cobra fish carapace man help`) says which
sources to ask, in order.

## Agents

Agents run commands in the project's first shell (opened if there's none,
without taking your screen) with the `shell` [tool group](agents.md#tool-groups):

| Tool | |
|---|---|
| `shell_run` | Run a command line and get back its id, exit code, output and errors (cut to whole lines at their start and end when long), how long it took, where `cd` went and what it set, the files and lines it names, its JSON, and a table's columns, first 50 rows and how many there are |
| `shell_read` | A block by id, or the latest one, yours too |
| `shell_wait` | Wait for a block `shell_run` left running past its `timeout_s` |
| `shell_kill` | Stop a block an agent ran |

An agent's commands run through a pipe with their input closed, from the
project's root unless they ask for a folder, in `sh` without its startup
files. Their blocks are marked `◆`, and their `cd` and `export` show in
their block without changing your shell. What a command prints goes back
to the model marked as someone else's text, to use as information and not
to follow; `greed ctl` gets it as it is. `shell-agent-max-output` (30000
bytes) is how much of the output and of the errors an agent gets; where
it's cut says how many lines are left out and that `$ID | where`, `select`
or `get` narrows it.

Each block has one id, unique across shells, and in an agent's command
`$ID` is that block, whichever shell it ran in, so `shell_run` with
`$12 | where STATUS != Running` works on what block 12 printed. A tool
called without an argument it needs, or with one it doesn't take, says
which it takes and runs nothing; `greed ctl shell_run --help` lists them.

## Limits

- A program in a pseudo terminal that prints faster than the shell reads
  (`seq 1 10000000`, a huge `cat`) can lose lines in between, and its
  block says how many. A flood of output belongs in a pipe: `$`-lines,
  `> buf:` and agents' commands run through one, which keeps every line.
- Blocks don't survive a restart yet.
- Only the client a block ran from sizes its terminal.

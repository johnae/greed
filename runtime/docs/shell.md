# The shell

`:shell` opens a shell in a buffer, and `greed --shell` starts Greed in
one. You type a command at the prompt at the bottom, `enter` runs it,
and it becomes a block above the prompt: the command, what it printed,
and how it ended. Blocks stay, so you can
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
context and namespace `kubectl` would use, which the `kubernetes` plugin
adds. The context comes from kubectl's config file, the ones `KUBECONFIG`
names or `~/.kube/config`, read without running kubectl, so it's there
at once and costs nothing. They're worked out again after every command,
so a `cd`, a checkout or `kubectl config use-context` shows on the next
prompt.

```text
⎇ main ⎈ prod-eu:payments ~/s/infra ❯ kubectl get pods
```

In a project with a devenv environment, `❄ devenv` shows too (see [Project
environments](#project-environments)).

A context matching a pattern in `shell-production-contexts` (`prod` by
default; several go with spaces between them, as Luau patterns, like
`:set shell-production-contexts "prod ^live%-"`) shows in red, and so
does the `❯`, so a command about to run against production looks like it.

`space o k` (`:kube-context`, or a click on the context in the prompt)
switches the context, from a list of those your kubeconfig has with their
namespaces, the current one and production ones marked; `space o K`
(`:kube-namespace`) switches the namespace, from those the cluster has.
`enter` switches everywhere, as `kubectl config use-context` does;
`ctrl-s` switches only in this shell, which then reads a small kubeconfig
of its own ahead of yours, so other shells and terminals keep theirs: prod
in one shell and staging in the next. `:kube-context NAME` switches
straight to one, and `:kube-context! NAME` only in this shell.

Plugins add pieces of their own, like a cloud profile; `help prompt` lists
them.

Each piece has a color of its own from the theme (`shell.segment.git`,
`shell.segment.kubernetes`, `shell.segment.environment`). With a Nerd Font,
`:set shell-icons nerd` uses its icons in place of `⎇ ⎈ ❄`.

If you use [starship](https://starship.rs), `:set shell-prompt starship`
shows your starship prompt instead, as your other shells do, with its
colors: Greed runs `starship prompt` after each command with the shell's
folder, variables, the last exit code and how long it took. The `❯` stays
Greed's own, red in production, so starship's prompt character is left
out. Put it in your config to keep it:

```lua
greed.option.set("shell-prompt", "starship")
```

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
| `enter` | At the prompt, run what's there. On a running block's line above the prompt, open the block in a float. On a block, put its command at the prompt to change; on a file and line it names, open it there; on a row that's a thing (a file, a pod), do its usual action |
| `alt-enter` | Another line at the prompt |
| `up` `down` | At the prompt: the commands typed before that start with what's typed |
| `ctrl-r` | Pick a command typed before, in any shell |
| `right` `end` `ctrl-e` | At the end of the prompt, take the rest of the command it suggests |
| `tab` | Complete a program, its arguments and flags, a file or folder, a variable, `$3`, `buf:` or `@sel`: the only match or what they all start with at once, else a menu, which `tab` again goes through |
| `ctrl-c` | Interrupt the running block |
| `ctrl-t` | Type into the running block's program, in a terminal in the shell's place |
| `[ p` `] p` | The block before or after the cursor |
| `g o` | Select the block's output |
| `] e` `[ e` | The next or previous file and line the output names |
| `space r` `space R` | Run the block again as it ran, or in the shell's folder now |
| `space C` | Change the block's command and run it in the block's place |
| `space y` `space Y` | Copy the block's output, or its command |
| `space x` | Stop the running block for good |
| `space v` | Open the block's whole output in a buffer |
| `space c` | Take the finished blocks away |
| `/` | On a block's output, keep the lines (or a table's rows) with what you type; elsewhere, search |
| `space s` `space S` | Sort a table by the column under the cursor; show a block as it came |
| `tab` `shift-tab` | On a block, fold it under its command or unfold it; fold or unfold every block (see [Folding blocks](#folding-blocks)) |

In the vscode style you're always typing, so the keys that need normal
mode have others: `ctrl-c` copies when something is selected and
interrupts otherwise, `ctrl-up` and `ctrl-down` go between blocks, `f8`
and `shift-f8` between the files and lines the output names, `ctrl-f`
filters a block, `ctrl-k ctrl-l` folds or unfolds a block (`ctrl-k ctrl-0` folds
them all, `ctrl-k ctrl-j` unfolds them all), and the `space` keys above are
`ctrl-space` ones.
`space .` (`alt-.` in the vscode style) on a block, or on a row that's a
thing (see [Rows you can act on](#rows-you-can-act-on)), lists what you
can do with it.

## Folding blocks

A folded block shows only its command line, with how it ended and how many
lines it hides (`⋯ 240 lines`), so a long session stays easy to look
through. `tab` on a block folds or unfolds it, and `shift-tab` folds or
unfolds them all. A block that's still printing stays folded as its output
grows.

Resting the mouse on a folded block shows it in a float without moving the
cursor: scroll it there, or click into it to filter it with `/` and act on
its rows. Moving the mouse away closes it.

Blocks can fold by themselves. Blocks that failed never do, since those are
the ones to read again:

```luau
local greed = require("@greed")
-- Fold a block that printed more than 40 lines as it ends.
greed.option.set("shell-fold-lines", 40)
-- Running a command folds the finished blocks above it.
greed.option.set("shell-fold-older", true)
```

## What runs your commands

The shell runs a few commands itself:

| Command | |
|---|---|
| `cd [DIR]` | Change the shell's folder: a path, `-` for the one before, nothing for home |
| `export NAME=VALUE ...` | Set variables for the commands after |
| `unset NAME ...` | Leave variables out of the commands after |
| `env [reload]` | List the variables this shell sets or leaves out, and the environment its folder brings (devenv, direnv); reload loads that again |
| `history` | The commands typed before |
| `clear` | Take the finished blocks away |
| `open PATH ...` | Open files, or `buf:NAME` buffers, in the editor |
| `help [TOPIC]` | What works here, and the keys in the style you use; a topic for one part |
| `which NAME ...` | What a word at the start of a line runs: a builtin, a table stage, one of your aliases or a program |
| `stop [N ... \| all]` | Stop running blocks by their number, or all of them; without one, list them |
| `watch [-n SECONDS] COMMAND` | Run a command again and again, every two seconds, its block showing what it printed last with the changes marked |
| `prom QUERY [--range DURATION] [--step DURATION] [--url URL]` | Ask Prometheus: a row a series as it is now, or over a range a row a time, to table or chart |

What `open` opens comes up in your style's own mode, to read and move
around in, not typing as at the prompt. Plugins add commands of their own
([Writing plugins](plugins.md#the-shell)), and `help builtins` lists them
with these.

Every other line goes to your shell, so `ls` and `ls | head` behave the
same: your `$SHELL` when it's a POSIX shell (sh, bash, zsh, dash, ksh and
the like), fish or nu, and `sh` otherwise; `:set shell-fallback bash` picks
one. `cd` and `export` there carry over to the commands after, as they
would in a terminal. If `shell-fallback` names a shell of another kind, the
line still runs in it, and its block says `cd` and `export` in it don't
carry over. Your shell's startup files aren't read for each line, so its
functions aren't there unless you `:set shell-fallback-rc true`.

With nu, a table a line gives back (`ls`, `ps`, `open data.csv | where
size > 10`) is data in the block as well as drawn by nu: its rows are
things like any table's (see [Rows you can act on](#rows-you-can-act-on)),
and the stages work on it with its real values: sizes in bytes, dates
in full. Its first 10000 rows are kept that way. nu numbers each row so
the shell knows which line is which.

Your aliases are. The shell asks your shell for them once, with its
startup files, and a line starting with one runs what it stands for, as
in a terminal; the block shows what you typed. The shell's own commands
win over an alias of the same name, `^NAME` runs the program `NAME`
whatever else has that name (`^env`, or `$3 | ^sort` for the `sort`
program rather than the table stage), and `which NAME` says what runs.
`:set shell-aliases false` leaves aliases alone.

As in bash and zsh, `!!` in a line is the command before, `!$` its last
word, and a line `^old^new` runs the command before with `old` changed to
`new`. The block shows the command as it ran.

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

## Project environments

In a folder with a `devenv.nix`, the shell loads devenv's environment, as
`devenv shell` would, and its commands run with it: the project's tools on
the `PATH`, its variables, and what `enterShell` sets up. No direnv is
needed, and devenv's own rule applies: a project loads once you've run
`devenv allow` there. The prompt says it's there, `❄ devenv`, with `…`
while it loads (a command typed meanwhile waits for it, and `ctrl-c` runs
it without), or that it failed, which `env` says more about.

Changing `devenv.nix`, `devenv.yaml`, `devenv.lock` or anything else devenv
read loads it again; `env reload` does too. Leaving the project leaves its
environment behind, and what you `export` wins over it. Every shell in a
project shares one load, and an agent's commands get it too.

A folder with an `.envrc` and no `devenv.nix` loads it through
[direnv](https://direnv.net), when that's installed and you've run `direnv
allow` there, the prompt saying `❄ direnv`. Changing the `.envrc` loads it
again; for other files it reads, `env reload` does. A project with both,
like an `.envrc` holding `use devenv`, gets devenv's straight away.

`shell-environments` (`devenv direnv`) says which kinds load and which
is asked first; `:set shell-environments ""` turns them off. Plugins add
other kinds.

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

After a command's first word, `$3` is a file holding what block 3
printed, for programs that read files rather than their input:

```text
❯ diff $3 $5
❯ kubectl apply -f $7
❯ open $3
```

The file ends `.json` when the block printed JSON. Single quotes keep
`$3` as it is (`awk '{print $3}'`), and so does `\$3`.

## Filtering and tables

Most output is text, and stays text. On top of it the shell keeps what it
can read out of it, and every layer below works on what's under it.

### Filtering a block

`/` on a block's output keeps the lines with what you type in them, as you
type it; several words keep the lines with all of them, in any case
(`shell-filter-search-case` changes that), and a filter that starts with
`/` is a regex (`/^error|warn`). `enter` keeps the filter; `esc`, while
typing it or after in normal mode on the block, shows every line again,
and `space S` also undoes a sort. The block shows the lines kept and the
status says so (`2 of 340 lines · / error`),
while its record keeps them all, so `$3`, `space y` and `space v` give the
whole output. On a block's command or at the prompt, `/` searches as
usual.

### Tables

Output in columns under a header, as `kubectl get`, `docker ps`, `ps aux`
and `df` print it, is also kept as a table on the block, and the status
says so (`table · 12 rows`). So is `ls -l`'s output. The shell looks for a
header in capitals with the columns lined up under it in every row, and
when it isn't sure, the output is text: prose is never taken for a table.

A table the shell draws itself (after a stage, a filter or a sort) shows
its values as people read them: sizes in bytes as `142.6 kB`, dates as
`3 h ago` (or the date, past a week), nested JSON as `{4 fields}` or
`[12 items]`, numbers lined up on the right, and a cell wider than 48
columns cut with `…`. The values stay as they were, so `sort size` sorts
by bytes, and `space h i` on a row shows them whole.

A table's header is set apart, and in a column saying how things are
doing (`STATUS`, `STATE`, `PHASE`, `READY`) `Running` or `Completed`
shows green, `Error` or `CrashLoopBackOff` red and `Pending` yellow, as
does `READY` short of all (`0/1`); `<none>` and nested JSON show faint.
The colors are the theme's `shell.table.header`, `.good`, `.bad`,
`.warn` and `.dim`. A table nu drew keeps nu's own colors.

A table's rows don't wrap in a narrow pane: what's past the edge is cut,
and the view scrolls sideways when the cursor goes there (or with the
wheel sideways, shift and the wheel in most terminals). Other output wraps
as text does.

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

`sort` without a column, or with a flag, is the `sort` program, as always.

They work after a program too, in one line: what it prints is read as a
table, as a block's output is, and the stages run on that.

```text
❯ kubectl get pods | where STATUS != Running | select NAME,AGE
❯ docker ps --format json | where Image ~ postgres
❯ $1 | grep api | where RESTARTS > 0
```

`where`, `select`, `get`, `columns`, `from`, `lines`, `filter`, `map`,
`count`, `group`, `first`, `to` and `each` start the stages after a
program, since no program goes by those names. `sort`, `split`, `uniq`,
`sum` and `last` are programs too: after a program they're the stages
when given something that isn't a flag (`ls | sort size -r`, `ls | last
2`), and the programs otherwise (`sort`, `sort -n`); `^sort` is always
the program. What the program prints before the stages isn't shown,
only what comes out at the end, and its errors. A stage on output that
isn't a table says so, and what makes one.

Some programs are asked for JSON when stages follow them, so the stages
read their data rather than columns on screen: `kubectl get` gets `-o
json`, `docker ps` and `docker stats --no-stream` get `--format json`.
The table has the columns the program prints itself (`READY`, `STATUS`,
`RESTARTS`, `CPU %`), and the status says `read as data` with the line
that ran. A line asking for its own output (`-o wide`, `--format`) or
watching runs as typed, and when the JSON form fails (an old docker,
say) the line runs again as typed and its table is read instead.

### More stages

| | |
|---|---|
| `filter EXPR` | The rows a Luau expression holds for, with the row's cells as r and its numbers as n |
| `map COL = EXPR` | A column made (or changed) by a Luau expression on r and n |
| `count` | How many rows there are |
| `first [N]` | The first N rows, one without N |
| `last N` | The last N rows |
| `uniq COL` | The first row for each value in a column |
| `sum COL` | The numbers in a column added up |
| `group COL` | Each value in a column and how many rows have it |
| `to json\|csv\|tsv` | The table as JSON, CSV or tab separated values |
| `each COMMAND` | Run a command for every row, {COL} in it the row's cell, quoted |

`filter` and `map` take Luau. In it, `r` is the row, its cells as text
(`r.STATUS`, `r["CONTAINER ID"]`), and `n` the cells that read as numbers,
sizes and ages included (`n.RESTARTS`, `n.AGE` in seconds). It runs in a
sandbox that can read the editor and nothing more, so a line an agent
wrote can't do anything else either. A column that isn't there says which
there are, and `n.NAME` of a cell that isn't a number says to read it as text,
`r.NAME`. Fractions a `map` makes show to two places; the values stay as
they are.

```text
❯ kubectl get pods | filter n.RESTARTS > 0 and r.STATUS ~= "Running"
❯ kubectl get pods | map hours = n.AGE / 3600 | sort hours -r | first 5
❯ kubectl get pods | group STATUS
❯ kubectl get pods | where STATUS = Evicted | each kubectl delete pod {NAME}
❯ docker ps | to csv > buf:containers.csv
```

`each` runs its command once for every row, with `{COL}` the row's cell,
quoted for your shell; the commands run one after another in your shell
and print into the block. What comes after `each` is all the command, so
`each echo {NAME} | wc -c` counts each name.

Plugins add stages of their own ([Writing plugins](plugins.md#the-shell)),
and `help tables` lists them all.

### JSON

Output that's JSON is kept as a value on the block (`JSON · 3 items`),
and an array of objects is a table too, with a column for each key, so
`/` and `space s` show it lined up in columns, and `$3 | where` works on
it. Many tools print JSON when asked, which is the surest way to a table:
`kubectl get pods -o json` gives every field, where its columns give a
few. A command on its own runs as typed; the shell reads what it
printed.

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

## Watching a command

`watch COMMAND` runs a command again and again, every two seconds (`-n 5`
for every five), and its block shows what it printed last in place of
what it printed before, with the lines that changed since the time before
marked. It's the shell's own, so it stays a block among the others
rather than taking the screen; `^watch` runs the watch program in a
terminal.

```text
❯ 7 watch kubectl get pods       ◐ 1m12s · every 2s · 1 changed · 14:05:02
NAME                     READY   STATUS             RESTARTS   AGE
api-7d9f8b6c5-2xkqz      1/1     Running            0          3d16h
worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   13         2h
```

The table and its [rows](#rows-you-can-act-on) follow along: a `/` filter
or a `space s` sort stays on what each run shows, `space .` on a pod acts
on it as it is now, and `$7 | where STATUS != Running` reads
what it shows. The whole line is watched, pipes and table stages
included, so `watch kubectl get pods | where RESTARTS > 0` shows only the
pods that restarted, as they are now. `ctrl-c` or `space x` stops it,
keeping what it showed last; it also stops by itself after
`shell-watch-minutes` (60), and `space r` starts it again. Agents can't
watch, as a watch runs until someone stops it.

`kubectl get pods -w` needs no `watch`: kubectl prints a pod again each
time it changes, and the block shows each pod once, in its place, lined
up under the header, the ones that changed since they first showed
marked, rather than a longer and longer list. Its rows are pods to act
on, as any `kubectl get` block's are. It ends when kubectl does, or with
`ctrl-c`.

`space C` on a block changes its command and runs it in the block's
place: the same number, where it was, its floats still showing it, with
what it printed, its filter and its sort replaced. A watch or `-w` block
stays live, so one block can go from pods to deployments rather than the
shell filling up with them. On a `kubectl get` block, `space .` offers
"another resource" (the ones the cluster has, its custom resources too)
and "another namespace" (or all of them), which do the same with the
resource or namespace flags changed, as k9s's views do:

```text
❯ 7 kubectl get pods -n payments -w        ◐ 2 changed · 14:05:02
       ↓ another resource: deployments
❯ 7 kubectl get deployments -n payments -w ◐ 0 changed · 14:05:09
```

## Charts

`| chart` draws a table as a chart, in characters every terminal shows:
braille for lines, eighth blocks for bars, in the theme's colours.

```text
❯ 4 kubectl top pods | chart
api-7d9f8b6c5-2xkqz    ████████████▊ 0.25
worker-5c6b7d8f9-abcde ████████████████████████████████████████████ 1.2
redis-0                █▊ 0.035
ingest-6f7c-xyz        ████████████████████████████████▌ 0.64
```

It guesses the chart from the columns:

| The table | The chart |
|---|---|
| A name column and numbers (`kubectl top pods`) | Bars of the first number, a row each |
| A time column and numbers | A line a number column, over time |
| Numbers only | A line a column, row by row; two columns are dots, one against the other |
| Text that isn't a table (`cat /proc/loadavg`) | Its words as columns, a first line without numbers as the header |

In the window (`greed --gui`) and in a terminal with kitty graphics
(kitty, Ghostty, WezTerm, Konsole) the chart is drawn as an image, smooth
lines and bars in the theme's colours, with its labels and numbers still
text. `:set scene-drawing cells` keeps charts in characters everywhere,
and `GREED_IMAGES=none` in one terminal.

Numbers keep their unit: `128Mi` and `1.5Gi` for bytes, `250m` for
kubectl's CPU, `45%` for percents, on the axis and beside the bars. Bars
of two columns in different units, like CPU and memory, are each as long
as their own greatest.

Anything it guesses can be said: `chart bar CPU MEMORY` (both, a bar
each), `chart line rate over time`, `chart area`, `chart scatter`,
`chart bar --stacked`, `chart --log`, `--width` and `--height` (it's as
wide as the view and `chart-height` lines tall, 12). When it can't draw
one, it says why, naming the columns it found. `chart --why` shows how
it read each column and why it picked the chart it did:

```text
❯ 5 kubectl top pods | chart --why
NAME           names, for the rows
CPU(cores)     numbers, in cores, charted
MEMORY(bytes)  numbers, in bytes, left out

bar: CPU(cores) by NAME: api-7d9f8b6c5-2xkqz 250m, worker-5c6b7d8f9-abcde 1.2, redis-0 35m, +1 more
because the rows have names (NAME): a bar each, of CPU(cores)
```

In a watch every run adds a point, so the chart is of how the numbers
went: `watch -n 2 kubectl top pods | chart` draws a line a pod, of its
CPU, over the last 120 runs (`--last` keeps another number). A watch
drawing a chart doesn't mark its lines changed, as they all do.

On a [board](boards.md), `chart` after a card's language draws it as a
chart as big as the card.

### Prometheus

`prom QUERY` asks a Prometheus server (`prometheus-url`,
`http://localhost:9090` unless you set it, or `--url`) and gives a row a
series, named by its labels' values, as a table to read or chart:

```text
❯ prom 'sum by (job) (rate(http_requests_total[5m]))' | chart
api      ███████████████████████████████████ 41.2
worker   ████████▌ 9.8
```

`--range 1h` asks for the last hour instead, a row a time with a column a
series, which `| chart` draws as a line a series (`--step 30s` sets the
time between points). In a watch, `watch -n 5 prom 'QUERY' | chart`, each
run adds a point, so the chart moves as Prometheus's numbers do; on a
board, a card with `every=5` does the same.

## Running blocks above the prompt

A watch, or anything else still running, scrolls up out of sight as you
run more commands. So every running block but the last gets a line just
above the prompt, saying what it shows now (how many rows, for a table)
and what changed in it last, or how long it has run:

```text
❯ 9 git status --short                    ✓ 0.02s
 M src/main.rs

◐ 7 watch kubectl get pods  · 3 pods · api-7d9: STATUS Running → Error · 14:05
◐ 8 cargo build --release   · 1m 12s
~/s/infra ❯
```

What changed names the row: `new worker-abc`, `worker-abc gone`, or the
first column that changed, with how many more rows did. Columns that
change by themselves, like `AGE` or the `(5m ago)` of `RESTARTS`, don't
count, so a quiet watch stays quiet. To hear about changes while you're
in another window, `space .` on the block (or its line) and "notify on
changes" (`shell-notify`): each change then sends a desktop notification
saying the same, while Greed isn't focused. Again to stop.

Such a line stands for its block, a line or two up from the prompt:
`ctrl-c` or `space x` there stops that block rather than the latest,
`space .` lists what you can do with it, and `space r` runs it again.
`enter` (or a click on its number) opens the block in a float, and `/`
opens it there to filter. The float shows that block and nothing around it,
and works as the block does in the shell: `/` filters it, `enter` or
`space .` on a row acts on the pod or file it is, and `ctrl-c` stops it.
A watch's float follows it as it refreshes. `esc` closes it, keeping the
filter, which a watch keeps on each run. `space .` on any block offers
"open in a float" too. A line goes when its block ends.

These floats stay while you work elsewhere, one for each block, so you
can keep several watches, logs and builds in sight at once: opening
another leaves the others open, and opening one again goes to it. They
are the tab's floats, so `alt-w` lays them out (`tiled`, `cascade`, one
at a time), `alt-{` and `alt-}` go between them and `alt-f` hides them
all and shows them again. The float the mouse opens resting on a folded
block is the only one that goes by itself, when the mouse moves away.

At the prompt, `ctrl-c` stops the latest running block and says which
others still run. `stop` lists them by number, `stop 7` stops block 7,
and `stop all` stops them all.

From anywhere, even a file you're editing, `space o w` lists what runs
in every shell, this project's first, with each one's output beside it:
`enter` opens it in a float, `ctrl-o` goes to it in its shell, and
`ctrl-x` stops it.

## Rows you can act on

Some tables' rows are things: an `ls -l` row is a file or a folder, a
`ps` row a process, a `kubectl get` row a pod, deployment or other
kubernetes object (from the `kubernetes` plugin), a `docker ps` row a
container (from the `docker` plugin). Some are known by their columns,
whatever printed them: a row with a `PID` (from `ps` on any
system, `lsof`, `docker top`) is a process, and rows with a name and a
type of `file` or `dir`, as nu's `ls` gives, are files. In a repository,
`git status` (short or long) and `jj st` list changed files (`diff`,
`open`, `restore`, and with git `stage` and `unstage`), `git log` lists
commits (`show`, `checkout`, `cherry-pick`, `revert`) and `jj log`
revisions (`show`, `diff`, `new`, `edit`, `squash`, `abandon`), from the
`vcs` plugin; each command names the repository the block ran in. The
status says so
(`table · 5 pods`). On such a row, `space .` lists what you can do with
it, the same actions that kind of thing has anywhere in Greed, and
`enter` does the usual one: a file opens, a folder becomes the shell's
folder, a pod or another kubernetes object is described, a container
shows its logs. `ctrl-o` (`alt-left` in the vscode style) comes back from
a file you opened to the row you opened it from.

A file offers `open`, `float`, `split`, `rename`, `delete`, `diff` (what
changed since the last commit), `reveal in tree` and `copy-path`; a folder
`cd`, `new shell here`, `grep here`, `rename`, `delete` and `reveal in
tree`; a process `stop`, `interrupt`, `hang up`, `kill`, `open files` and
`its folder`. These are the same wherever a file or folder shows up, a
path in any buffer included.

Select several rows (`x` a few times in Helix, `V` in Vim, shift and the
arrows in the vscode style) and `space .` offers each action once for all
of them (`describe  3 × pod: api-0, api-1, api-2`), running it on each in
turn. One that deletes or stops asks once for all of them (see below).

`watch` on a row (or anything else, under `space .`) looks at it again
every `watch-interval` seconds (10) and sends a notification when it
changes, on the status line and to your desktop, saying how:

```text
worker-5c6b7d8f9-abcde: RESTARTS 12 → 13; STATUS Running → CrashLoopBackOff
```

A pod is looked at with `kubectl get pods NAME`, a container with `docker
ps`, a process with `ps -p`, each run where its row came from. Once it's
gone the notification says so and watching it stops. `watch` again stops
it, and `:watches` lists what's watched.

```text
❯ 4 kubectl get pods                      ✓ 0.38s · table · 3 pods
NAME                     READY   STATUS             RESTARTS   AGE
api-7d9f8b6c5-2xkqz      1/1     Running            0          3d16h
worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   12         2h      ← space .
                                   describe · logs · follow logs · shell
                                   yaml · json · events · delete
```

What an action does is a command, run as a block of its own, so you see
it, can run it again and change it:

```text
❯ 5 kubectl logs worker-5c6b7d8f9-abcde --tail 200 --context prod-eu -n payments
```

`follow logs` on a pod or a container opens its block in a float that
stays on the last line as lines come, like `tail -f`; move up to read and
it stays put, go back to the last line and it follows again. `esc` closes
the float and the logs keep coming in the line above the prompt, where
`ctrl-c` stops them. An action whose command still runs in the shell
doesn't start a second one: it opens the one running (`already running as
$7`).

A row remembers where it came from. The kubernetes context and namespace
are the ones the command ran against, from its flags or else kubectl's
config as it was when the block finished, so acting on a row of an old
block after `kubectl config use-context` still goes to that row's
cluster, and the command says which. With `-A`, each row's namespace is
its own. `docker --context` is kept the same way.

Actions that delete or stop something (`delete`, `restart`, killing a
process, stopping a container) ask first, and say so when the row is in
a context matching `shell-production-contexts`:

```text
delete worker-5c6b7d8f9-abcde - in PRODUCTION (prod-eu)? y/n
```

For several at once, or for any an agent asks to run, a review lists each
with the command it runs, every one ticked: `space` unticks one, `a`
ticks or unticks them all, `enter` runs the ticked ones and `esc` none.

```text
[x] delete  worker-5c6b7d8f9-abcde   kubectl delete pods worker-5c6b7d8f9-abcde --context prod-eu -n payments   (in PRODUCTION (prod-eu))
[ ] delete  api-7d9f8b6c5-2xkqz      kubectl delete pods api-7d9f8b6c5-2xkqz --context prod-eu -n payments   (in PRODUCTION (prod-eu))
```

`shell` on a pod or a container opens a shell in it in a terminal.

What the blocks above showed completes the next command. After `kubectl
get pods`, `kubectl logs <tab>` offers those pods first, each saying which
block it's from (`pod · $4`), then whatever kubectl itself offers; so do
`exec`, `describe pod`, `delete deploy` and `rollout restart deployment`
for theirs. Only rows from where the command goes are offered: the
context and namespace its flags name, or else kubectl's config now.
`docker logs <tab>` offers the containers of a `docker ps` above, and
`kill <tab>` the processes of a `ps`.

Rows are objects too, so `space h i` on one shows its
cells, the block it's in and its actions. A row of a known kind is named
by what it is: `pod:prod-eu/payments/api-7d9f8b6c5-2xkqz`, `process:4711`,
`container:web`, `file:/home/me/notes.txt`. The same pod in a newer block
is the same object, and the newest row is the one found. The rows of any
other table are plain rows of their block (`row:12.3.2`, the third block
of buffer 12, its second row), with their cells as their state.

Some cells are things of their own: the node a pod runs on (`kubectl get
pods -o wide`) and its namespace (with `-A`) are kubernetes objects, and a
container's image is an image, which `inspect`, `history` and `pull` work
on. `space .` on such a cell offers the row's actions first, then the
cell's (a node's `describe`, an image's `pull`), and the inspector lists
them among the row's relations. A namespace or a node is named as kubectl
names it, `namespace/billing`.

Any cell of any table is something to act on too: `copy` copies what's
in it, and `filter by this` keeps the rows with the same in that column
(`STATUS=Running`; with spaces in it, the rows with its words). A plain
row copies as text, its cells with tabs between them, or as a JSON
object. Agents reach them the same way, through the `objects`, `inspect`
and `act` tools: a block's rows are among the objects it relates to.

Plugins add kinds of rows and actions of their own
([Writing plugins](plugins.md#the-shell)).

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

As you type, the prompt suggests the rest of the newest command that
starts with what's there, dimmed after the cursor, as fish does: `right`,
`end` or `ctrl-e` at the end takes it, and typing on goes past it.
`:set shell-suggestions false` turns it off.

```text
~/s/app ❯ cargo t|est -q --workspace
```

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

- A command's first word: the builtins, your aliases and the programs on
  your `PATH`; after `$3 |`, the stages too.
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

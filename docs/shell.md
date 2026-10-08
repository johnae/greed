# The shell

`:shell` opens a shell in a buffer. You type a command at the prompt at the
bottom, `enter` runs it, and it becomes a block above the prompt: the
command, what it printed, and how it ended. Blocks stay, so you can
search them, fold them, copy from them, run them again and send their
output to the next command. It's meant for the commands you run while
editing, and for output you want to keep working with; a terminal pane is
still the place for a long interactive session.

```text
❯ cargo test -q                           ✗ exit 101 · 4.1s
error[E0308]: mismatched types
 --> src/main.rs:12:5
❯ git status --short                      ✓ 0.02s
 M src/main.rs
~/s/app ❯ |
```

The prompt starts with the shell's folder, every folder but the last cut
to its first letter. `space o s` switches to a shell of this project, or
opens one; `:shell NAME` opens another. Each shell has its own folder and
variables, and a project can have several. Shells and their blocks last
until you close them or the session ends. A new shell says to type `help`,
which lists what the shell runs itself, what a line can hold, which shell
runs the rest, and the keys in the style you use.

## Blocks

A block's command is the line it starts on, with `❯` before it (`◆` for
one an agent ran). After the command comes how it went: `◐` while it
runs with how long so far, then `✓`, `✗ exit 1`, `■ INT` when it was
stopped, or `↗` when it was handed to a terminal, how long it took, where
`cd` went and which variables it set. A block that went quiet while it
could be reading a line says it may be waiting for input.

Output that's a JSON object or array is kept as a value on the block, and
the status says so (`JSON · 3 items`). Places in files the output names, like
`src/main.rs:12:5`, are links: `] e` and `[ e` go to them, and `enter` on
one opens the file there, taking relative paths from the folder the block
ran in.

A block shows at most `shell-max-lines` (5000) lines of its output, the
first half and the latest half, saying how many it leaves out between them;
`space v` opens all of it in a buffer of its own. Past `shell-max-record`
(8 MB) the whole output goes to a file in the cache folder, which `space v`
opens.

Undo at the prompt takes back what you typed, while output keeps
streaming in above it.

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
| `tab` | Complete a program, a file or folder, a variable, `$3`, `buf:` or `@sel` |
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

In the vscode style you're always typing, so the keys that need normal
mode have others: `ctrl-c` copies when something is selected and
interrupts otherwise, `ctrl-up` and `ctrl-down` go between blocks, `f8`
and `shift-f8` between the files and lines the output names, and the
`space` keys above are `ctrl-space` ones. `space .` (`alt-.` in the vscode
style) on a block lists what you can do with it.

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
| `help` | What works here, and the keys in the style you use |

Every other line goes to your shell, so `ls` and `ls | head` behave the
same: your `$SHELL` when it's a POSIX shell (sh, bash, zsh, dash, ksh and
the like), fish or nu, and `sh` otherwise; `:set shell-fallback bash` picks
one. `cd` and `export` there carry over to the commands after, as they
would in a terminal. If `shell-fallback` names a shell of another kind, the
line still runs in it, and its block says `cd` and `export` in it don't
carry over. Your shell's startup files aren't read, so aliases and
functions aren't there unless you `:set shell-fallback-rc true`.

Programs get `PAGER=cat` and `GIT_PAGER=cat`, so their output comes back as
text, and `GREED_BIN`, the greed program running the editor.

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
sets them up. Without one, a block says why.

## History and completion

The commands you type at every shell are kept in your data folder
(`~/.local/share/greed/shell/history.jsonl`), the last
`shell-history-size` (5000) of them, so `up` and `ctrl-r` find them in
every session. `tab` completes programs on your `PATH` and the builtins as
a command's first word, files and folders from the shell's folder after
it, variables and earlier blocks after `$`, buffers after `buf:`, and
`@sel` and `@file`. An agent's commands aren't kept.

## Agents

Agents run commands in the project's first shell (opened if there's none,
without taking your screen) with the `shell` [tool group](agents.md#tool-groups):

| Tool | |
|---|---|
| `shell_run` | Run a command line and get back its exit code, output and errors (cut to their start and end when long), how long it took, where `cd` went and what it set, the files and lines it names and its JSON |
| `shell_read` | A block by id, or the latest one, yours too |
| `shell_wait` | Wait for a block `shell_run` left running past its `timeout_s` |
| `shell_kill` | Stop a block an agent ran |

An agent's commands run through a pipe with their input closed, from the
project's root unless they ask for a folder, in `sh` without its startup
files. Their blocks are
marked `◆`, and their `cd` and `export` show in their block without
changing your shell. What a command prints goes back to the model marked
as someone else's text, to use as information and not to follow; `greed
ctl` gets it as it is. `shell-agent-max-output` (30000 bytes) is how much
of the output and of the errors an agent gets.

## Limits

- A program in a pseudo terminal that prints faster than the shell reads
  (`seq 1 10000000`, a huge `cat`) can lose lines in between, and its
  block says how many. A flood of output belongs in a pipe: `$`-lines,
  `> buf:` and agents' commands run through one, which keeps every line.
- Blocks don't survive a restart yet.
- Only the client a block ran from sizes its terminal.

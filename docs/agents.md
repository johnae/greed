# Agents

Agents use Greed the way you do, as clients of the running editor. They can
read buffers with your unsaved changes, see what you have selected and what
the language servers report, open files for you, and propose edits that
you review in the buffer. Every tool is also a shell command, for scripts
and agents that prefer a CLI.

## From the shell: `greed ctl`

```bash
greed ctl tools                       # what the editor offers
greed ctl focus                       # the current file, selections, visible lines
greed ctl read path=src/main.rs from_line=10 to_line=20
greed ctl diagnostics
greed ctl eval code='return require("@greed").mode.get()'
```

Arguments are `key=value` pairs (values that parse as JSON are JSON) or one
JSON object. `greed ctl` talks to the running session: the one named by
`$GREED_SESSION`, or the only one running. Each session's socket is readable
only by you and needs a token from a file only you can read.

## Claude Code and other MCP clients

```bash
claude mcp add greed -- greed mcp
```

`greed mcp` connects an MCP client to the running editor. The tools:

| Tool | What it does |
|---|---|
| `focus` | The current file, your selections with their text, the lines on screen |
| `buffers` | Open files and which have unsaved changes |
| `read` | A file as the editor has it, unsaved changes included |
| `diagnostics` | Errors and warnings from language servers |
| `history_recent` | What changed lately in open files, who changed it (you, a plugin, an agent, the disk) and a diff |
| `context_get` | What you pinned for agents: selections, files, problems, the changes in progress |
| `outline` | A file's functions and types with their lines, from its syntax tree |
| `syntax_query` | Run a tree-sitter query over a file and get what it matched |
| `open` | Open a file for you, at a line |
| `propose` | Propose edits to one or more files for you to review |
| `project` | The project's root folder |
| `eval` | Run Luau inside the editor; what it edits is one operation you can review and undo |
| `describe` | What a command, option, event, API function, plugin or mode is: its doc, keys, value, who defined it and where |
| `plugin_guide`, `plugin_try`, `plugin_install` | Write a plugin (below) |
| `notes_list`, `notes_search`, `notes_read`, `notes_write` | Your notes: find, read, write and add to them |
| `notes_todos`, `notes_add_todo` | The todos in your notes, soonest due first, and adding one |

`eval` can do anything a plugin can. Leave it out of an agent's allowed
tools if you don't want that.

## Reviewing proposed edits

`propose` takes a file and a list of edits, or several files each with its
own, each edit replacing some exact text with new text. The old text is
struck through in the buffer and the new text shows after it; when whole
lines change, as in Claude Code's diffs, the new lines show under the old
ones, with the words that changed picked out on both. Nothing changes
until you decide, with the keys or by clicking `accept` or `reject` after
each change:

| Keys | |
|---|---|
| `] o` `[ o` | Next and previous proposed change |
| `space o a` `space o r` | Accept or reject the changes your selections touch |
| `space o A` `space o R` | Accept or reject every change in the file |
| `space o o` | Pick from every pending change |
| `space o d` | Show the file with every change in, beside it; again to hide |

Changes follow the edits you make while they wait. The agent waits too, and
then hears which changes went in. What you accept from one proposal is an
operation (see [Using Greed](using.md#operations)): `space u u` undoes it in
every file at once, and `space u o` reviews it.

Side by side, the two panes scroll together, matching lines across the
changes, and the right one keeps up as you edit, accept and reject.

## Claude Code's `/ide`

`space o c` opens Claude Code in a pane beside your files, already
connected to Greed; pressed again it goes back to that pane, or brings it
back if you closed it. `claude` started in any Greed terminal connects by
itself too. `:set claude-command "claude --continue"` changes what the pane
runs.

Started outside Greed, in the same project, `/ide` in Claude Code lists Greed
next to any other editors. Once connected:

- Claude Code sees your selection as you move, and `space o m` mentions the
  selected lines to it.
- Its edits arrive as proposed changes, reviewed with the keys above. If
  you accept some of them, Claude Code learns which.
- It can read diagnostics, open files and check for unsaved changes.

Greed writes a lock file to `~/.claude/ide` so Claude Code can find it, and
removes it when the session ends.

## Agents inside Greed

Greed can also run agents itself, over the Agent Client Protocol (ACP): Claude
Code (through `claude-code-acp`), Gemini CLI, Codex, or any agent that
speaks it. Each gets a transcript buffer, and several can work at once.

| Keys | |
|---|---|
| `space i n` (`:agent-new`) | Start an agent: pick which, and where it works |
| `space i o` (`:agents`) | The agents: what each is doing, and their changes |

The transcript shows what you and the agent said, the tools it ran and how
they went, and its plan. Write below the prompt line at the bottom and
press `alt-enter` to send; `ctrl-c` stops the agent's turn. When it asks
before doing something, `enter` (or `alt-p`) answers: `y` allows once, `a`
always, `n` rejects. The agent reads open files as you have them, unsaved
changes included, and its edits to an open file are made in the buffer and
saved, so undo takes them back.

An agent works either in the project with you, or in a workspace of its
own: a jj workspace, or a git worktree on a branch `greed/NAME`, in Greed's
cache folder. There it can change what it likes without touching your
files. In the agents overview:

| Keys | |
|---|---|
| `enter` | Open its transcript |
| `d` | What it changed in its workspace, as a diff |
| `b` | Bring that into your working copy: with jj its change is squashed into yours, with git its diff is applied |
| `s` | Stop its turn |
| `x` | Stop it and remove its workspace, after asking |
| `n` | Start another |

A jj workspace starts from your working copy's parent, so it doesn't see
changes you haven't committed. Add an agent that isn't in the list in your
`init.luau`; the first of its commands that's installed is used:

```luau
require("@acp").register({
	name = "goose",
	title = "Goose",
	commands = { { "goose", "acp" } },
})
```

## Plugins written by agents

An agent can extend Greed while you work:

1. `plugin_guide` gives it the plugin conventions and the full typed API.
2. `plugin_try` writes a plugin to a staging folder and checks it: strict
   types against the API, then the plugin's own tests in a headless editor.
   The agent gets back what failed and tries again.
3. `plugin_install` asks you. A panel shows what the plugin may do beyond
   the editor (its [capabilities](plugins.md#capabilities), like running
   programs or reading files), the code and the check results; `a` installs
   it into `~/.config/greed/plugins`, approves what it asks for and loads it
   right away, `r` rejects it.

Ask for something like "a command that jumps from a `use` line to the
crate's entry in Cargo.toml" and the agent goes through these steps. You
only see it once its checks pass.

## Writing your own tools

Any plugin can offer tools; see [Writing plugins](plugins.md#agents).

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
| `working_set` | The files you've worked in lately, most active first, with how much you and agents edited each and the lines you were on |
| `repo_map` | A map of the project: the functions and types that matter most, with their files and lines, ranked toward what you're working on (below) |
| `symbols` | Functions and types anywhere in the project whose names match, with their files and lines |
| `grep` | The lines matching a regex in the project, with open files searched as you have them, unsaved changes included |
| `files` | The project's files, or those whose paths match a fuzzy query |
| `outline` | A file's functions and types with their lines, from its syntax tree |
| `syntax_query` | Run a tree-sitter query over a file and get what it matched |
| `open` | Open a file for you, at a line |
| `propose` | Propose edits to one or more files for you to review |
| `ask` | Ask you questions, with choices or a typed answer, on a page you fill in and send; the answers come back to the agent |
| `project` | The project's root folder |
| `eval` | Run Luau inside the editor: sandboxed first, then a reviewer or you for anything more (below); what it edits is one operation you can review and undo |
| `describe` | What a command, option, event, API function, plugin or mode is: its doc, keys, value, who defined it and where |
| `why` | How some lines came to be: each change that made them, newest first, with its description and diff |
| `plugin_guide`, `plugin_try`, `plugin_install` | Write a plugin (below) |
| `notes_list`, `notes_search`, `notes_read`, `notes_write` | Your notes: find, read, write and add to them |
| `notes_todos`, `notes_add_todo` | The todos in your notes, soonest due first, and adding one |
| `plan_read`, `plan_write` | The plan you share (below): its checklist as you have it, and replacing it |
| `decisions`, `decision_read`, `decision_propose` | What was decided for the project, and proposing a decision for you to accept |
| `subagent` | Hand a task to a helper agent with an empty context, in a workspace of its own by default, and get its report (below) |
| `blocks_list`, `blocks_run` | The runnable code blocks in a Markdown file, and running one, in files you trust; the result is saved under the block |

### The repo map

`repo_map` gives an agent a few thousand tokens' worth of the project's
layout: the first line of each function and type that matters most,
grouped by file. Greed reads every source file's syntax tree, links each
file to the files defining the names it uses, and ranks them toward your
working set, so the map changes with what you're working on.
`:repo-map` shows what an agent would get now.

The working set is the files you've worked in lately. Your edits count
most, an agent's edits less, and moving around in a file a little; what you
did 15 minutes ago counts half as much as what you do now. `:working-set`
shows it.

### What `eval` may do

`greed ctl eval` from a shell runs as you: whoever runs it can already run
anything. For agents, through `greed mcp`, Claude Code's `/ide` or Greed's
own agents, `eval` runs as the `agent-eval` option says:

| Value | |
|---|---|
| `"auto"` (the default) | Sandboxed first: the code can read the editor and how it's set up (options, keys, plugins), open files in the project and edit buffers, and nothing else. When it needs more (running programs or commands, other files, keys, options, plugins), a reviewer decides: the model playing the `review` role, or `fast` (see `:models`). If the reviewer isn't sure, or there's none, you're asked. |
| `"ask"` | You see the code and press **Run** every time |
| `"allow"` | It runs with every capability, as a plugin would |
| `"off"` | There's no `eval` |

The sandbox is enforced by the editor, so what it keeps out doesn't depend
on anyone reading the code right. Its edits are taken back before the code
runs again with more, so nothing happens twice. The reviewer reads the code
as data and answers in a fixed form, so the most a sneaky comment in the
code can do is make it ask you. When you're asked, the page shows the code,
what it would do and the reviewer's reason, with **Run**, **Allow for this
session** and **Deny**; closing it, or leaving it five minutes, denies.
`:eval-log` lists every run past the sandbox and who let it.

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

## Questions from agents

An agent that needs to know something can `ask`. Greed shows its questions
as a page in a float: each with choices to pick one of (`enter` or a click),
or a line to type after `Answer:`. **Send** gives your answers back to the
agent, and **Cancel**, or closing the page, tells it you didn't answer.

The agent sends questions as plain data, and Greed writes the page itself.
Its words go on lines of their own, with anything that could start
Markdown's syntax escaped, so a question can't add a button, a code block
or a choice of its own, and only you can send the page.

## A plan and decisions you share

An agent can keep its plan in `.greed/plan.md` in the project, a Markdown
checklist you see and change while it works: tick steps (`todo-toggle`),
reorder them, add or delete them. `:plan` opens it. The agent reads the
plan as you have it, and when it writes a new one it gives the version it
read; if you changed the plan since, its write is refused and it gets
yours to work from, so it can't write over your changes.

Decisions are kept in `.greed/decisions`, a file each: what was decided
and why, like "use SQLite" or "never edit the generated code". Agents read
them in later sessions and follow the accepted ones.

| Command | |
|---|---|
| `:decision-new TITLE` | Write down a decision, accepted |
| `:decisions` | Pick one to open |
| `:decision-accept` | Accept the proposed decision you're in |

A decision an agent adds is `Status: proposed` until you accept it, and
agents are told not to rely on proposed ones, so one agent can't make
rules for the next. These are plain files, though: an agent that can write
files can write here too, so check `.greed` changes as you would code.

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
Code (through `claude-agent-acp`), Gemini CLI, Codex (`codex-acp`), or any
agent that speaks it, found on your `PATH`. Each gets a transcript buffer,
and several can work at once.

| Keys | |
|---|---|
| `space i n` (`:agent-new`) | Start an agent: pick which, and where it works |
| `space i o` (`:agents`) | The agents: what each is doing, and their changes |
| `space i r` (`:agent-resume`) | Take up an earlier session with an agent, where it left off |
| `:agent-fork` | Fork the agent of the transcript you're in |

The transcript shows what you and the agent said, the tools it ran and how
they went (`tab` on a tool shows all its output), and its plan. Write
below the prompt line at the bottom and press `alt-enter` to send;
`ctrl-c` stops the agent's turn. When it asks before doing something,
`enter` (or `alt-p`) answers: `y` allows once, `a` always, `n` rejects.
The agent reads open files as you have them, unsaved changes included,
and its edits to an open file are made in the buffer and saved, so undo
takes them back.

Agents also get Greed's own tools, the ones `greed mcp` offers above
(diagnostics, outlines, `syntax_query`, `propose`, ...), connected to this
session. `:set agent-greed-tools false` leaves them out.

While an agent works you see where: the line it's on in an open file gets
a `◆` beside it and the agent's name and what it's doing at the end, in a
colour of its own (an agent in a workspace shows on your copy of the
file). The status line says how many agents are working and how many wait
for you.

`alt-m` picks the mode the agent works in, when it has modes (Claude Code
has Manual, Accept edits and Plan); the transcript's first line shows the
one it's in.

Some questions can be answered for you. An agent in a workspace of its own
edits, moves and deletes files there without asking, since nothing reaches
your files until you bring it in (`:set agent-workspace-edits false` to be
asked anyway). Rules of your own go in `init.luau`; the first that returns
an option's id answers, and `nil` leaves it to the next, and in the end to
you:

```luau
require("@acp").policy(function(session, question)
	-- Reading files never needs asking.
	if question.kind == "read" then
		for _, option in question.options do
			if option.kind == "allow_once" then
				return option.id
			end
		end
	end
	return nil
end)
```

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
| `f` | Fork it: a new session that starts with everything said so far |

A jj workspace starts from your working copy's parent, so it doesn't see
changes you haven't committed. A fork of an agent in a jj workspace gets a
workspace of its own with the edits made so far; in a git worktree, it
starts from the branch's last commit.

Sessions are kept in the cache folder until you close them with `x`, so
after a restart `space i r` lists them, with what you asked first, and
takes one up: the agent tells the conversation again into a new
transcript, and its workspace is still there. Agents that can't take up a
session (or fork one) say so.

An agent can start another with the `subagent` tool: for a search across
the project, a side task or a second opinion, without filling its own
context. The helper is an agent from the list here (the first installed,
or the one asked for), in a workspace of its own unless the caller says
otherwise. Its transcript shows in `:agents` and it asks you before doing
things like any other; the caller gets its last answer as a report. At
most three work at once, so helpers starting helpers can't run away.

Add an agent that isn't in the list in your
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

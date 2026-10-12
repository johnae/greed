# Agents

Agents use Greed the way you do, as clients of the running editor. They can
read buffers with your unsaved changes, see what you have selected and what
the language servers report, open files for you, and propose edits that
you review in the buffer. Every tool is also a shell command, for scripts
and agents that prefer a CLI. What they may do without asking you is in
[Permissions and sandboxing](permissions.md).

## From the shell: `greed ctl`

```bash
greed ctl tools                       # what the editor offers
greed ctl read --help                 # what a tool does and the arguments it takes
greed ctl focus                       # the current file, selections, visible lines
greed ctl read path=src/main.rs from_line=10 to_line=20
greed ctl diagnostics
greed ctl eval code='return require("@greed").mode.get()'
```

Arguments are `key=value` pairs (values that parse as JSON are JSON) or one
JSON object; an argument a tool doesn't take, or a missing one it needs, is
an error naming the ones it takes. A relative path is from the root of the
project Greed shows, wherever Greed or the agent was started, and `~` is
your home folder.
`greed ctl` talks to the running session: the one named by
`$GREED_SESSION`, or the only one running. Each session's socket is readable
only by you and needs a token from a file only you can read.

## Claude Code and other MCP clients

```bash
claude mcp add greed -- greed mcp
```

`greed mcp` connects an MCP client to the running editor. As it connects,
the client is told where your config is and how to add to Greed with a
plugin, so an agent asked to change a setting or add a command knows where
to go. The tools:

| Tool | What it does |
|---|---|
| `focus` | The file you are in (the last one, while an agent's pane has focus), its view and buffer ids, your selections with their text, the lines on screen, the mode (as `greed.mode.get()` names it, like `helix-insert`, with the status line's `insert` as its label) and the editing style |
| `buffers` | Open files and which have unsaved changes |
| `read` | A file as the editor has it, unsaved changes included, or a buffer or view by its id (`buffer:12`) |
| `diagnostics` | Errors and warnings from language servers |
| `history_recent` | What changed lately in open files, who changed it (you, a plugin, an agent, the disk) and a diff |
| `context_get` | What you pinned for agents (`space i p`, see [the context](using.md#the-context)): selections, files, problems, the changes in progress, objects as they are now |
| `working_set` | The files you've worked in lately, most active first, with how much you and agents edited each and the lines you were on |
| `repo_map` | A map of the project: the functions and types that matter most, with their files and lines, ranked toward what you're working on (below) |
| `symbols` | Functions and types anywhere in the project whose names match, with their files and lines |
| `grep` | The lines matching a regex in the project, with open files searched as you have them, unsaved changes included; also in your config and its plugins, and Greed's own plugins and types |
| `files` | The project's files, or those whose paths match a fuzzy query; or a folder's, in the project, your config or Greed's own plugins |
| `outline` | A file's functions and types with their lines, from its syntax tree |
| `syntax_query` | Run a tree-sitter query over a file and get what it matched |
| `open` | Open a file for you, at a line |
| `propose` | Propose edits to one or more files for you to review |
| `rename` | Rename a name everywhere it's used, as the language server works it out, proposed for you to review |
| `code_actions`, `code_action` | The language server's quick fixes and refactors for some lines, and proposing one; actions that would run a command in the server are refused, since they can't be shown first |
| `ask` | Ask you questions, with choices or a typed answer, on a page you fill in and send; the answers come back to the agent |
| `project` | The project's root folder |
| `objects`, `inspect`, `act` | The objects of the running editor (buffers, views (panes, floats and panels like an agent's chat), tabs, terminals, shells and their blocks, language servers, proposals, agent sessions, plugins and what plugins add): list them by kind or by what they relate to, see one's state, relations, actions and what was done to it (by you or an agent), and run an action on it as you would from the inspector (`space h i`), like closing a view or a buffer by its id; `act` says back what each object was and the views after, when they changed. Actions run in the view you were in, as `run_command` does. Agents in Greed ask before `act`, which takes several ids at once; an action that deletes or stops something always goes to you to review first, all of them together, whatever the agent was allowed, and you may run some and not others. Deciding on proposed changes stays yours |
| `commands`, `run_command` | Find the editor's commands by words in what they do (those matching the most words first), with how each is typed and what its arguments are, and run one with its arguments checked as the command line checks them (a wrong one gives back the usage and nothing runs). It runs in the view you were in (the one `focus` reports, never the agent's own chat), or in the view the agent names, and says back which view that was and, when views closed or opened, the views there are now. A command that may close, delete or stop something asks you every time, naming the view it would run in |
| `eval` | Run Luau inside the editor: sandboxed first, then a reviewer or you for anything more (below); what it edits is one operation you can review and undo |
| `describe` | What a command, option, event, API function or type, plugin or mode is: its doc, keys, value, who defined it and where; `greed.tab` lists a module's functions and `View` a type's methods |
| `why` | How some lines came to be: each change that made them, newest first, with its description and diff |
| `plugin_guide`, `plugin_try`, `plugin_install` | Write a plugin (below) |
| `debug_log` | What Greed and its plugins say they do while a debug topic is on (keys, runs, frames, language server messages, programs, a plugin's own `greed.debug.log` lines): turn topics on, do the thing, read the lines |
| `notes_list`, `notes_search`, `notes_read`, `notes_write` | Your notes: find, read, write and add to them; rewriting a note that's there is proposed for you to review |
| `notes_todos`, `notes_add_todo`, `notes_add_thought` | The todos in your notes, soonest due first, and adding a todo or a thought |
| `notes_update_todo` | Change one todo: its text, due date or reminder, or tick it |
| `notes_remind` | Set a reminder on a line of a note, or add a todo with one ("remind me this evening") |
| `plan_read`, `plan_write` | The plan you share (below): its checklist as you have it, and replacing it, which gives back the version to write with next |
| `decisions`, `decision_read`, `decision_propose` | What was decided for the project, and proposing a decision for you to accept |
| `memory_list`, `memory_propose` | Your standing preferences (below), and proposing one for you to accept |
| `subagent` | Hand a task to a helper agent with an empty context and get its report; Greed's own agent has it from the start (below) |
| `blocks_list`, `blocks_run` | The runnable code blocks in a Markdown file, and running one, in files you trust and as you last ran it; the result is saved under the block |
| `web_search`, `web_fetch` | Search the web with the service you set up, and read a page as text (below) |
| `shell_run` | Run a command in the project's [shell](shell.md), where you see it marked ◆, and get back its id, exit code, output, errors, how long it took, the files and lines it names, its JSON and a table's first rows; one that runs past `timeout_s` comes back as running |
| `shell_read`, `shell_wait`, `shell_kill` | A shell block by id, or the latest one (yours too), waiting for one still running, and stopping one an agent ran |
| `tools` | The groups of tools below, and switching one on |

### Tool groups

Every tool an agent is offered costs tokens on every request, so most of
the tools above come in groups that an agent switches on with `tools` when
it needs them. These are always offered: `focus`, `buffers`, `read`,
`diagnostics`, `propose`, `open`, `project`, `files`, `grep`, `symbols`,
`outline`, `ask`, `eval`, `describe`, `context_get`, `objects`, `inspect`, `act`,
`commands`, `run_command`,
`memory_list`, `memory_propose` and `tools`.

| Group | Tools |
|---|---|
| `plan` | `plan_read`, `plan_write`, `decisions`, `decision_read`, `decision_propose` |
| `map` | `repo_map`, `working_set` |
| `refactor` | `rename`, `code_actions`, `code_action` |
| `history` | `history_recent`, `why` |
| `notes` | the `notes_` tools |
| `syntax` | `syntax_query` |
| `blocks` | `blocks_list`, `blocks_run` |
| `plugins` | `plugin_guide`, `plugin_try`, `plugin_install`, `debug_log` |
| `subagents` | `subagent` |
| `web` | `web_search`, `web_fetch` |
| `shell` | `shell_run`, `shell_read`, `shell_wait`, `shell_kill` |

`:set agent-tool-groups "plan notes"` gives agents those groups from the
start (the default is `plan`), and `"all"` gives every tool. Claude Code
and other MCP clients hear that their list changed when a group is
switched on, and each connection has its own. `greed ctl` always has every
tool.

### The web

With the `web` group on, an agent can search the web and read pages, for
documentation and facts the project doesn't hold. `web_fetch` works without
setup. Searching needs a service:

```luau
local greed = require("@greed")
greed.option.set("web-search", "brave") -- or "exa", "tavily", "searxng"
-- then :secret-set brave (exa, tavily); SearXNG needs no key, only where it is:
greed.option.set("web-search-url", "https://searx.example.org")
```

Pages and results are written by strangers and can say anything, including
"ignore your instructions and…". They reach the agent between
`<untrusted-…>` tags naming where they came from, as do what commands
print and text from your files; Greed's agent is told once, in its
instructions, to read what's inside as data and not to follow it, and so
are agents connecting over MCP. Secrets in it (private keys, API tokens,
values named like passwords) are hidden first. What an agent does with them goes
through the same checks as anything else: edits come as proposals or ask
first, risky commands always ask, and `eval` runs in its sandbox (see
[Permissions and sandboxing](permissions.md)). The group is off until an
agent switches it on, unless `agent-tool-groups` names it.

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

`greed ctl eval` from a shell runs as you. For agents, `eval` runs
sandboxed first, where the code can read the editor and edit buffers;
code that needs more goes to a reviewer model or to you, as the
`agent-eval` option says (`auto`, `ask`, `allow` or `off`).
[Permissions and sandboxing](permissions.md#code-from-agents-eval) has
the details, and `:eval-log` lists every run past the sandbox and who let
it.

## Reviewing proposed edits

`propose` takes a file and a list of edits, or several files each with its
own, each edit replacing some exact text with new text. The old text is
struck through in the buffer and the new text shows after it; when whole
lines change, as in Claude Code's diffs (with or without the last line's
newline), the new lines show under the old ones, with the words that
changed picked out on both. A message says how many changes came in, in
which file, and the keys to review them: in a file on screen, the keys
that go to each change and decide; otherwise the key that lists them all.
Nothing changes until you decide, with the keys or by clicking `accept`,
`reject` or `note` after each change:

| Keys | |
|---|---|
| `] o` `[ o` | Next and previous proposed change |
| `space o a` `space o r` | Accept or reject the changes your selections touch |
| `space o n` | Reject them and tell the agent what to do instead: what you type goes back to it with the change, so it can propose again |
| `space o A` `space o R` | Accept or reject every change in the file |
| `space o o` | Pick from every pending change |
| `space o d` | Show the file with every change in, beside it; again to hide |

Changes follow the edits you make while they wait; one whose own text you
edited isn't accepted over your edit (undo it, or reject the change). The
agent waits too, and then hears which changes went in, with the errors and
warnings the language server reports in those files once it has seen them,
so it can fix what it broke without running the compiler. An agent that goes away while its
proposal waits, like a Claude Code session you quit, takes the proposal
with it: what's left of it is rejected. What you accept from one proposal is an
operation (see [Using Greed](using.md#operations)): `space u u` undoes it in
every file at once, and `space u o` reviews it. A file the undo takes back to
what's saved no longer shows as changed.

Side by side, the two panes scroll together, matching lines across the
changes, and the right one keeps up as you edit, accept and reject.

## Questions on a page (`ask`)

An agent that needs to know something can `ask`. (Questions about whether
it may do something are in [Permissions and sandboxing](permissions.md).) Greed shows its questions
as a page in a float: each with choices to pick one of (`enter` or a click),
if it has any, and a line to type your own answer after `Answer:`, alone or
to go with a choice. **Send** gives your answers back to the
agent, and **Cancel**, or closing the page, tells it you didn't answer.
`enter` picks the choice under the cursor and goes on to the next
question, starts typing on an `Answer:` line, and from there goes on to
the next, and on the last line sends; `ctrl-s` sends from anywhere on the
page.

The agent sends questions as plain data, and Greed writes the page itself.
Its words go on lines of their own, with anything that could start
Markdown's syntax escaped, so a question can't add a button, a code block
or a choice of its own, and only you can send the page.

## A plan and decisions you share

An agent can keep its plan in the project's notes (`.greed/notes/plan.md`,
the note `project:plan`; see [Using Greed](using.md#notes-in-a-project-and-other-places)),
a Markdown checklist you see and change while it works: tick steps
(`space n x`), reorder them, add or delete them. `:plan` opens it, and its
open steps are in your agenda with your other todos. The agent reads the
plan as you have it, and when it writes a new one it gives the version it
read; if you changed the plan since, its write is refused and it gets
yours to work from, so it can't write over your changes.

Agents like Claude Code and opencode keep todo lists of their own. To have
them use this plan instead, say so in the project's `AGENTS.md` or
`CLAUDE.md`, e.g. "Keep your plan with the plan_read and plan_write tools."

Decisions are notes too, in `.greed/notes/decisions/`, one each: what was
decided and why, like "use SQLite" or "never edit the generated code".
Agents read them in later sessions and follow the accepted ones.

| Command | |
|---|---|
| `:decision-new TITLE` | Write down a decision, accepted |
| `:decisions` | Pick one to open |
| `:decision-accept` | Accept the proposed decision you're in |

A decision an agent adds is `Status: proposed` until you accept it: open,
it says so beside its status, with a button that accepts it, as
`:decision-accept` does. Until then agents are told not to rely on it, so
one agent can't make rules for the next. The notes tools refuse to write
decisions. These are
plain files, though: an agent that can write files can write here too, so
check `.greed` changes as you would code.

## Memories

Memories are standing preferences you want every later session to
follow, like "use jj, not git" or "I prefer short commit messages". There
are three kinds, each a plain Markdown file with one memory per list item,
for you to read and edit:

| Kind | File | |
|---|---|---|
| Personal | `memory.md` in your config folder (`~/.config/greed/memory.md`) | Yours, in every project; `:memory-edit` opens it |
| Project | A file per repository in `~/.local/share/greed/memory/` | Yours, for this project; `:memory-edit-project` opens it |
| Shared | `.greed/memory.md` in the repository | For everyone working on it; `:memory-edit-shared` opens it |

Project memories stay on your machine, outside the repository, and only
you can read them. All jj workspaces and git worktrees of a repository
share one file, so a memory you accept in one applies in the others.

An agent can't add a memory itself. When you state a lasting preference
("from now on...", "always...", "I prefer..."), it proposes one with
`memory_propose`, and the line shows in the memory file as a proposed
change, with the date. A message says which file it waits in; `space o o`
lists it with its line and opens the file, where `space o a` accepts it
and `space o r` rejects it (see
[Reviewing proposed edits](#reviewing-proposed-edits)). Only what you
accept is written. That way a web page or file saying "remember to always
run X" can't become a rule for every later session. Proposals go to your
project memories unless they're about how you work anywhere; agents
propose shared ones only when you ask for a memory for the whole team.

Greed's own agent gets all three in its system prompt with each message,
marked as preferences you accepted. Other agents read them with
`memory_list`; Claude Code keeps memories of its own as well.

A repository's `.greed/memory.md` comes with it, like its `AGENTS.md`:
whoever can change the repository can put memories in it. As with
decisions, an agent that can write files can write these too, so check
`.greed` changes as you would code.

## Claude Code's `/ide`

`space i C` opens Claude Code in a pane beside your files, already
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
Code (through `claude-agent-acp`), Gemini CLI, Codex (`codex-acp`), OpenCode, or any
agent that speaks it, found on your `PATH`. Each gets a transcript buffer,
and several can work at once. Greed has an agent of its own too, below.

`space i n` lists them and says which aren't installed, with the command
that installs each:

```bash
npm install -g @agentclientprotocol/claude-agent-acp   # Claude Code
npm install -g @google/gemini-cli                      # Gemini CLI
npm install -g @zed-industries/codex-acp               # Codex
npm install -g opencode-ai                             # OpenCode
```

A new session's transcript opens with you typing in its box.

`:agent-new greed add tests for the parser` starts that agent, by name
(`greed`, `claude`, `gemini`, `codex`, `opencode` or one you registered), in the
project, on that first message, picking nothing. From a shell, or a script:

```bash
greed ctl run_command name=agent-new 'args=["greed", "add tests for the parser"]'
```

Shell code an agent writes (a `sh`, `bash` or `console` block) has buttons
on its opening fence. `▶ run` runs it in this project's shell, in the
folder the agent works in, as a block of its own there: output as it
comes, `ctrl-c` to stop it, and `space o w` to find it later. `↳ prompt`
puts it at that shell's prompt to look over and change first, and `⧉ copy`
copies it. Click one, press `enter` on the fence to pick, or `space .` on
it. A command that destroys, stops or sends something (`rm`, `kill`, `git push`,
`kubectl delete`, `curl -X DELETE` and the like) asks y/n before it runs,
saying why. A
`console` block's commands are its lines after a `$ ` prompt.

To show the agent a screenshot, copy it and press `alt-v` in the
transcript; in the window, the paste keys do it too when the clipboard
holds an image. The image goes with your next message, shown as a chip in
the box (`🖼 image 1 · 1280×720`), and `alt-x` drops it. It's read from
the clipboard of the machine you're at, so with `greed ssh` it's your
laptop's, and kept in Greed's cache folder where the agent runs. An agent
that can see images gets the image itself: Claude Code, and Greed's own
agent when its model can (Claude, GPT-4o and later, Gemini, Kimi K2.5 and
later, Qwen-VL, Llama 4 and the like, known by name; `images = true` on a
role says so for a model Greed doesn't know). One that can't is told
where the file is and that it can't see it, so it can still work with the
file. In a terminal, Greed reads the clipboard with `wl-paste` (Wayland),
`xclip` (X11) or `osascript` (macOS).

### Greed's own agent

Pick "Greed" in `space i n` for an agent that runs in the editor itself,
with any model the [models](using.md#models) setup knows: Anthropic's, or
any server with OpenAI's API, like berget, Mistral or a local Ollama. It uses the
model playing the `agent` role (or `reasoning` without one); `alt-M` in its
transcript picks another role, and `:models` sets which model plays it.
"Another model…" at the end of `alt-M`'s list picks a provider and then
one of the models it lists, and switches to it: that model plays `agent`
from then on, as if picked in `:models`.
When that model's provider has no key, the bottom of the transcript says
so in place of "ready", and a message you send stays in the box until
there's one.

```luau
local models = require("@models")
models.roles.agent = { provider = "berget", model = "the model you want" }
-- then :login berget for a Berget Code plan, or :secret-set berget for an API key
```

It has the tools the list above gives agents (the repo map, working set,
grep, symbols, diagnostics, the plan, ...) but `propose`, plus `edit_file`,
`write_file`, `move_file`, `delete_file` and `run` for shell commands (a
block of the project's shell, marked ◆, with the project's environment): its
edits show the change and ask first, so a proposal left for review isn't
needed. Reading never asks. Editing, moving, deleting, running and
fetching ask (`y` once, `a` for every action of that kind for the rest of
the session, `n` no), and your policies answer them too. So do the tools
above that write, run or fetch something, like `notes_write`, `blocks_run`
and `web_fetch`, by the kind of thing they do; tools that show you their
work themselves, like `propose`, `ask` and `eval`, don't ask first. A
risky command (`kubectl delete`, `git push`, `rm`, `docker rm`, `curl -X
POST`) asks every time, saying why, whatever you allowed, whether it comes
through `run` or `shell_run`. [Permissions and sandboxing](permissions.md)
has what asks and what you can answer for good. Its edits go
through the file's buffer, so `u` takes them back, and it hears what the
language server reports about the file right after. Several changes to a
file in one `edit_file` are one change to undo. It won't write a whole file
over one it hasn't read, or over your changes made since it read it, and
it can't write a line like `// ... existing code ...` in place of code it
left out. A file outside the project, your config too, asks before every
change, even with edits allowed always. When it edits your config, the
config runs again right away, and the agent hears whether it ran or what
error it hit, so a setting that doesn't exist gets fixed in the same turn.

By default the model edits by giving the text to replace. Some models copy
text badly and do better naming lines instead: with `edits = "hashline"`
on the role (or the provider), `read` gives each line a name of its number
and a short hash of its text (`12#a3f|local x = 1`), and the model edits
lines by those names. A line that moved since it was read is found by its
hash; one that changed is refused, so the model reads it again.

```luau
models.roles.agent = { provider = "berget", model = "moonshotai/Kimi-K3", edits = "hashline" }
```

When the model stops answering or its connection drops, the transcript
says so (`no reply for 90s; trying again in 2s`) and Greed asks once more,
unless some of the answer had already come. If that fails too, the turn
ends with why and `say go on to try again`; `ctrl-c` stops it at once,
during the wait before trying again too. [Models](using.md#models) says
how long a model may go quiet.

`:usage` shows how the edits went, by model and way of editing, to compare
the two, beside the tokens each model was sent and wrote today and over the
last week, and how many came from the provider's cache
([Models](using.md#models) has more). Its system
prompt includes the project's `AGENTS.md` or `CLAUDE.md`. For now it works
in the project itself, without a workspace of its own.

Each session is written down after every turn, so the [session
list](#the-session-list) (`space i l`) shows it with the other agents'
sessions and takes it up where it left off: the transcript comes back and
the conversation goes on with everything said so far, the same model and
the tool groups it had on. Your "allow always" answers aren't kept, so a
session taken up asks again. The files are in Greed's data folder
(`~/.local/share/greed/agent-sessions`), one folder per repository, which
all its jj workspaces and git worktrees share, readable only by you,
since they hold what you typed and what tools returned. Long tool output
is cut there. The newest 50 sessions of each repository are kept and
older ones deleted (`:set agent-sessions-kept 100` keeps more); closing
one with `x` in the session list deletes it. Agents don't read other
sessions' conversations; only you see them in the list.

A tool result longer than 2,000 lines or 30,000 characters reaches
Greed's agent as its start and where the whole of it is: a file in
Greed's cache folder (`agent-output`, only yours to read, cleared after a
week) that it reads on in or searches with `grep`, so nothing is lost.

Every request sends the whole conversation, so a long file read early on
costs again on every turn after. Providers cache the start of a
conversation that's the same as last time and charge much less for it, so
Greed's agent keeps that start steady: the system prompt doesn't change
from turn to turn (the time comes in each of your messages instead), a
tool group switched on adds its tools after the ones there already, and
requests to Anthropic mark the tools, the system prompt and the newest
message for caching. Old messages are never changed afterwards, except
when the conversation is compacted.

When a conversation nears the model's limit, it's compacted before the
next request: the model summarises everything but its end, and the
summary takes its place. The summary has fixed headings (objective, open
requests, decisions, work state, next step, the files that matter and
exact details still needed), folds in the summary before it when there
is one, and is followed by a pointer to the plan, which is kept apart
from the conversation. The end kept as it was is as many whole turns as
fit in about 15k tokens (a fifth of the window, for a small one), the
last turn at least, so a tool call and its result always stay together. Near the limit means the
conversation, as the provider last counted it plus what came since,
leaves less than room for the longest answer and a reserve (10% of the
context window or 16k tokens, whichever is more, but at most a quarter of
it). A request the provider still turns down as too long is compacted and
tried again, keeping half as much of the end each time, up to three
times. The transcript shows a folded `conversation compacted (N messages → summary)`
row; `tab` on it shows the summary. `:agent-compact` does it by hand, and
`:set agent-compact-at 200000` compacts once a conversation reaches that
many tokens, well before a large window fills: every request sends the
whole conversation, so a long one costs more each turn. The
summary goes to the model as its own earlier words rather than as
instructions, and the system prompt (your project's instructions, where
it works) is built fresh as always. The model playing the `compact` role
summarises, if you set one, and otherwise the session's own model:

```luau
models.roles.compact = { provider = "anthropic", model = "claude-haiku-4-5-20251001" }
```

Greed knows the context window of Claude, GPT and common open models
(Llama 3, Mistral Small, Devstral, Qwen3 Coder, GLM, DeepSeek, Gemma 3, Kimi,
gpt-oss) by their names, and
assumes 32k tokens for any other. Set `context` on the role or provider
when it's wrong, as for an Ollama model whose context you've raised:

```luau
models.roles.agent = { provider = "ollama", model = "qwen2.5-coder", context = 128000 }
```

One answer from Greed's agent may be up to 32k tokens long, or a quarter
of the context window when that's smaller; set `output` on the role or
provider to change it. An answer that runs out of room anyway, such as one
writing a long file, runs none of its tool calls. The agent is told and
goes on in smaller pieces, and stops after three such answers in a row.

| Keys | |
|---|---|
| `space i n` (`:agent-new`) | Start an agent, Greed's own or one over ACP: pick which, and where it works; one that isn't installed says the command that installs it |
| `:agent` | Show the latest session, or start one as `space i n` does when none runs |
| `space i l` (`:agent-list`) | The [session list](#the-session-list): every session of the repository, running and kept |
| `space i m` (`:agent-move`) | Move the transcript you're in to a pane, a tab, a float or a panel |
| `:agent-fork` | Fork the agent of the transcript you're in |
| `:agent-compact` | Compact the conversation with Greed's own agent now |

```text
▍ You
▍ Fix the off-by-one in the pager

▍ Claude
▍ Found it in pager.rs.
▍ ✓ Edit pager.rs · +1 -1
▍ ✗ Run cargo test · 12 lines ▸

╭─ Claude · Plan · Sonnet ────── alt-enter sends · ctrl-c stops ─╮
│ now add a test                                                 │
╰─ ● thinking · 12s ─────────────────────── 14.2k / 200k tokens ─╯
```

The transcript shows what you and the agent said, each with a coloured
bar beside it (yours on a shaded background), and its plan. Each tool call
is one row: `○` waiting, `◐` running, `✓` done or `✗` failed, with what
it was about and what came back in a few words, like `read src/main.rs ·
120 lines`. A `▸` means there's more: `tab` on the row shows all of its
output, and `tab` again folds it. When Greed's own agent asks before
editing a file, like your config, the edit's row already holds the change
(`-1 +1 · tab shows the change`): `tab` shows the lines going and the ones
coming, in the theme's diff colours, before you answer.

While the box is on screen, the transcript scrolls down as the agent
adds to it, taking your cursor back to the box (unless you're selecting
text). Scroll up away from the box and it stays where you are.

Write in the box at the bottom; it grows as you write, and its top shows
the agent, its mode and model. `alt-enter` sends and `ctrl-c` stops the
agent's turn, in any mode, while typing too (in the vscode style, with a
selection it copies): what it was answering or running is left behind at
once, and the next message carries on from there. A command it started in
the project's shell goes on there, where `ctrl-c` stops it.

Everything above the box is read-only. You can move, search, select and
copy there in any style, but typing, going into insert mode or pasting
there puts the cursor at the end of the box and types there, and deleting
there is refused. While the agent asks something, its keys answer from
anywhere in the transcript.

What you send while the agent works waits its turn, shown at the end of
the transcript as `You · queued` and counted under the box (`thinking · 1
queued`). Greed's own agent reads it at its next step, along with the
result of the tool it just ran; other agents get it as the next message
once their turn ends, several queued messages together. It then shows
where the agent got it. Messages still queued when you stop the agent stay
queued and go ahead of your next message (`alt-enter` on an empty box sends
them alone).

The box's bottom line says what the agent is doing (the tool it runs,
`waiting for mistral` until its model's answer starts, then `thinking` or
`writing`) and for how long this turn has taken, `waiting
for you` when it asks something, and how many tokens of the model's
context the conversation takes when the agent says (out of how many it
has room for, when it says that too; Greed's own agent always does). With the effects option on
(`:set effects true`), running tools spin, the status shimmers while the
agent thinks and the waiting chip pulses; nothing moves while the agent
is idle. Themes style it with `agent.you` (your messages' background),
`agent.you.bar`, `agent.bar`, `agent.box`, `agent.box.title`,
`agent.hint`, `agent.working`, `agent.waiting`, `agent.done` and
`agent.failed`.

When the agent asks before doing something, the question shows as a row
of choices at the top of the box, like
`Allow Edit a.txt?  [y] Allow once  [a] Allow always  [n] Reject`, and
you answer it from there in any mode and editing style: `enter` picks the
highlighted choice, `tab` moves, a choice's letter picks it and `esc`
rejects it, taking what you wrote in the box along as what to do instead
(`alt-enter` with a message does the same). [Answering an agent](permissions.md#answering-an-agent) has
the keys and what "Allow always" covers for each agent.
The agent reads open files as you have them, unsaved changes included,
and its edits to an open file are made in the buffer and saved, so undo
takes them back.

Each message you send takes along what you have on screen: the file you
were last in (the one beside the agent's pane while you type there), the
cursor's line and column, the selected text (cut after 4000 characters)
and the other files showing. It's marked as context from the editor, so
the agent treats the file text in it as data. When nothing changed since
your last message it isn't sent again. `:set agent-editor-context false`
turns it off.

Agents also get Greed's own tools, the ones `greed mcp` offers above
(diagnostics, outlines, `syntax_query`, `propose`, ...), connected to this
session. `:set agent-greed-tools false` leaves them out.

While an agent works you see where: the line it's on in an open file gets
a `◆` beside it and the agent's name and what it's doing at the end, in a
colour of its own (an agent in a workspace shows on your copy of the
file). The status line says how many agents are working and how many wait
for you.

`alt-m` picks the mode the agent works in, when it has modes (Claude Code
has Manual, Accept edits and Plan), and `alt-M` the model, when it offers
a choice (for Greed's own agent, a role or any model a provider lists);
the top of the box you write in shows both. The transcript is a buffer in
a panel: move and copy in it as in any other, and `:q` or
`ctrl-w q` closes the panel while the agent goes on (`space i l` brings it
back).

What the agent thinks before it answers shows as dimmed rows, for agents
that share their thinking (Claude Code does, and so does Greed's own agent
when its model's provider sends it, like Claude with an effort set or
Mistral's reasoning models). While a thought comes in you see its first
line, its newest few lines and how far along it is, so a long one doesn't
look stuck:

```text
▍ … The user wants the pager fixed.
▍   The last page is one short, so the count starts at 1 where the
▍   offset starts at 0. Check how pager.rs uses it before changing
▍   thinking · 8.2k tokens · 4m 10s
```

Once it's done it folds to its first line and its size
(`▸ The user wants the pager fixed. · thought, 8.2k tokens`; tokens are
counted roughly, four characters each). `tab` on the row shows all of it,
however long. `/thoughts` hides them in every transcript, and shows them
again; `:set agent-thoughts false` does the same from your config.

#### Slash commands

A message whose first word is one of Greed's chat commands runs it instead
of going to the agent:

| Command | What it does |
| --- | --- |
| `/model [name]` | Picks the model, as `alt-M` does; with a name, switches to it |
| `/mode [name]` | Picks the mode, as `alt-m` does; with a name, switches to it |
| `/thoughts` | Hides or shows what agents think |
| `/fork` | A new session that starts with everything said so far |
| `/effort [none\|low\|medium\|high\|max]` | Greed's own agent: how hard its model thinks, for this session; without a word, a picker |
| `/compact` | Greed's own agent: summarises all but its last few turns, to save room |

`/effort` changes the session only, shown at the top of the box
(`Greed · reasoning · effort high`); `/effort unset` goes back to what the
role says, and `e` in `:models` sets the role's own for every session.
Any other `/word` goes to the agent as you wrote it, so Claude Code's own
commands, like `/review`, work as they do in Claude Code, and so do
`/effort` and `/compact` for agents other than Greed's (and `/mode` or `/model`
for an agent that offers none). `tab` after the
`/` lists the commands that fit what you typed, Greed's and those the
agent offers, each with what it does.

### The session list

`space i l` lists the sessions of the repository you're in: those running
and those kept to take up again, from every jj workspace or git worktree
of it, with this one's first and then the newest. Each line says which
agent, what you asked it first, what it's doing (`working`, spinning
with effects on, `waiting for you`, `idle`, `failed` with why its last
turn failed, `exited` or `saved`), when it
last did something, the tokens it takes when the agent says, and where it
works: `in other-workspace` for one that ran in another workspace of the
repository, `workspace NAME` for one in a workspace of its own.

```text
  Claude    Fix the off-by-one in the pager  ⠋ working  just now   14.2k tokens
  Greed     Add a test for the pager         idle       4 min ago  3.1k tokens
  Claude 2  Look at the parser               saved      2 h ago                 in greed-b
```

| Keys | |
|---|---|
| `enter` | Show the session, taking it up first if it's kept or exited; with several marked, show them all as panes |
| `r` | Take up the session (or the marked ones) without showing it |
| `h` | Take up Greed's own session here, in the workspace you're in |
| `m` | Mark the session, or unmark it, to act on several |
| `p`, `t`, `w`, `s` | Show it in a pane, a tab of its own, a floating view or a panel on the right |
| `/` | Narrow the list to sessions with what you type in them; `esc` puts back the filter there was |
| `n` | Start another, asking which agent as `space i n` does |
| `f` | Fork it: a new session that starts with everything said so far (not Greed's own sessions yet) |
| `x` | Close it: stop it, forget it and remove its workspace, asking first when it's running or has a workspace |
| `d`, `b`, `R` | What it changed in its workspace, bring that in, or review it (below) |
| `ctrl-c` | Stop its turn |
| `q`, `esc` | Close the list |

A session taken up from another workspace works in the folder it ran in.
To carry on with one of Greed's own sessions where you are now, take it up
with `h`; from then on it's kept as this workspace's. Other agents, like
Claude Code, keep their sessions by folder, so theirs stay where they ran,
as do sessions in a workspace of their own.

A transcript shows in one place at a time, and moving it doesn't restart
the agent: `space i m` and then `p`, `t`, `w` or `s` moves the one you're
in to a pane, a tab, a float or a side panel (`:agent-show-pane`,
`:agent-show-tab`, `:agent-show-float`, `:agent-show-panel`). The box you
write in, its keys and the status line under it work the same in each.
Several marked sessions shown with `p` split the biggest pane each time,
with `t` they share one new tab, and with `w` each gets a float of its
own. Closing a transcript's view, its pane or its tab leaves the session
running; only `x` in the list, or quitting Greed, ends it.

Some questions can be answered for you. An agent in a workspace of its own
edits, moves and deletes files there without asking, since nothing reaches
your files until you bring it in (`:set agent-workspace-edits false` to be
asked anyway), and Greed won't write a file outside the workspace for it at
all. Rules of your own, policies in `init.luau`, can answer others, like
letting the agent run your tests. Some questions are always yours: risky
commands, and writes that let a plugin do more. See
[Permissions and sandboxing](permissions.md#policies).

An agent works either in the project with you, or in a workspace of its
own: a jj workspace, or a git worktree on a branch `greed/NAME`, in Greed's
cache folder. There it can change what it likes without touching your
files. In the session list:

| Keys | |
|---|---|
| `d` | What it changed in its workspace, as a diff |
| `R` | Review that on your files, change by change, as proposed edits (see [Reviewing proposed edits](#reviewing-proposed-edits)) |
| `b` | Bring that into your working copy: with jj its change is squashed into yours, with git its diff is applied |

`R` takes the agent's edits and moves them past whatever you've changed
since it started, so you review only what it did. An edit to lines you
changed too is left out, and the message says how many files had one;
`d` shows them. What you accept lands in your buffers, unsaved, and undoes
in one step. The agent's workspace keeps its change, so after a review
close it with `x` rather than bringing it in with `b`.

A jj workspace starts from your working copy's parent, so it doesn't see
changes you haven't committed. A fork of an agent in a jj workspace gets a
workspace of its own with the edits made so far; in a git worktree, it
starts from the branch's last commit.

Sessions are kept in the cache folder until you close them with `x`, so
after a restart `space i l` lists them, with what you asked first, and
takes one up: the agent tells the conversation again into a new
transcript, and its workspace is still there. Agents that can't take up a
session (or fork one) say so. Greed's own agent keeps its sessions itself,
as described above.

An agent can start another with the `subagent` tool: for a wide search or
survey whose details would fill its own context, a side task or a second
opinion. The helper is an agent from the list here (the one asked for, or
else the first installed), in a workspace of its own unless the caller
says otherwise. Its transcript shows in the session list and it asks you
before doing things like any other; the caller gets its last answer as a
report. At most three work at once, so helpers starting helpers can't run
away. A helper whose turn fails, like one whose model has no key, comes
back as an error saying why.

Greed's own agent has `subagent` from the start, and its helpers are
Greed's own agent with the same model unless it names another. Greed's
agent can't have a workspace yet, so as a helper it works in the project
and only reads and searches; told to work in the project (`here`), it
edits and runs commands too, asking you first as usual, and the result
says so. Several `subagent` calls in one answer run at once.

While a helper works, its call's row in the transcript shows the task,
what the helper is doing (its tool call, "thinking" or "waiting for you"),
how long it has worked and the tokens it has used, and the box's bottom
line says `waiting for 2 helpers`. `enter` on the row shows the helper's
own transcript in a float, during and after its work, and `ctrl-c` stops
the helpers along with the turn. When it's done, `tab` on the row unfolds
what it reported.

Add an agent that isn't in the list in your
`init.luau`; the first of its commands that's installed is used, and
`model` is the model it starts with, when it offers models, and `install`
the command `space i n` shows when it isn't installed:

```luau
require("@acp").register({
	name = "opencode",
	title = "opencode",
	commands = { { "opencode", "acp" } },
	model = "berget/llama-3.3-70b",
	install = "npm install -g opencode-ai",
})
```

Which models an agent offers is up to the agent: opencode, for example,
offers the ones its own config sets up.

## Plugins written by agents

An agent can extend Greed while you work:

1. `plugin_guide` gives it the plugin conventions and the full typed API.
2. `plugin_try` writes a plugin to a staging folder
   (`~/.cache/greed/staging`) and checks it: strict
   types against the API, then the plugin's own tests in a headless editor,
   with none of its capabilities until you approve it. It runs without
   asking you, since nothing it does reaches your editor or your files.
   The agent gets back what failed and tries again, sending only the files
   it changed: the rest come from its last try. Type errors count only in the plugin's own
   files, and tests that fail only because a capability isn't approved yet
   don't stop it going to you: once you install it, they run again with
   what you approved, and the agent hears how they did.
3. `plugin_install` asks you. A float shows what the plugin may do beyond
   the editor (its [capabilities](plugins.md#capabilities), like running
   programs or reading files), the code and the check results; `a` installs
   it into `~/.config/greed/plugins` (or `~/.local/share/greed/plugins` when
   your config can't be written, as when Nix manages it), approves what it
   asks for and loads it right away, `r` rejects it.

[Permissions and sandboxing](permissions.md#plugins-and-the-sandbox) says
what an approved plugin may do and how the sandbox keeps the rest out.

Pages like this one, and the one asking before an agent's code runs, show
one at a time: when an agent asks for two at once, the second shows once
you've answered the first, so neither waits hidden behind the other.

Ask for something like "a command that jumps from a `use` line to the
crate's entry in Cargo.toml" and the agent goes through these steps. You
only see it once its checks pass. Greed's own agent is told to build new
things for Greed this way rather than in the project you're in, and the
tools say so to other agents; it changes the project only when you ask it
to change the project.

## Writing your own tools

Any plugin can offer tools; see [Writing plugins](plugins.md#agents).

# Agents

Agents are clients of the running editor. They read buffers with your
unsaved changes, see your selections and the language servers' diagnostics,
open files and propose edits you review in the buffer. Every tool is also a
shell command (`greed ctl`). What they may do without asking is in
[Permissions and sandboxing](permissions.md).

There are four ways in:

- Greed's own agent, with any model you set up (Anthropic, OpenAI, Berget,
  Mistral, Ollama).
- An ACP agent run inside Greed: Claude Code, Codex, Gemini CLI, opencode.
- Any MCP client, using `greed mcp`.
- Claude Code's `/ide` connection.

## From the shell: `greed ctl`

```bash
greed ctl tools                       # what the editor offers
greed ctl read --help                 # what a tool does and the arguments it takes
greed ctl focus                       # the current file, selections, visible lines
greed ctl status                      # what needs you, and the agents at work
greed ctl watch                       # the same as JSON lines: at once, on each change, every 15 s
greed ctl read path=src/main.rs from_line=10 to_line=20
greed ctl diagnostics
greed ctl eval code='return require("@greed").mode.get()'
```

Arguments are `key=value` pairs or one JSON object. Values that parse as
JSON are JSON, and `key=@-` reads the value from standard input. An unknown
or missing argument is an error naming the ones the tool takes. Relative
paths are from the project's root; `~` is your home folder.

`greed ctl` talks to the session named by `$GREED_SESSION`, or the only one
running. Each session's socket is readable only by you and needs a token
from a file only you can read.

`greed ctl watch [SESSION]` prints the whole status as a JSON line at once,
again on each change (an agent starts waiting, a command finishes out of
sight), and at least every 15 seconds, so a script can tell a session that
went away from a quiet one. `greed ctl watch | jq` always shows the latest.

## Agents as MCP clients

Any agent that speaks MCP can use Greed's tools: add `greed mcp` as a
server. In the common ones:

```bash
claude mcp add greed -- greed mcp            # Claude Code
codex mcp add greed -- greed mcp             # Codex
gemini mcp add -s user greed greed mcp       # Gemini CLI
```

opencode takes it in its config (`~/.config/opencode/opencode.json`):

```json
{ "mcp": { "greed": { "type": "local", "command": ["greed", "mcp"] } } }
```

`greed mcp` connects an MCP client to the running editor. On connecting,
the client is told where your config is, how to extend Greed with a plugin,
and which [tool groups](#tool-groups) it can switch on. The tools:

| Tool | What it does |
|---|---|
| `focus` | What you are in, a file or not (the last one, while an agent's pane has focus), its view and buffer ids, your selections with their text, the lines on screen, the mode (as `greed.mode.get()` names it, like `helix-insert`, with the status line's `insert` as its label) and the editing style |
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
| `status` | This session at a glance: what needs you (an agent waiting for an answer, a command that finished out of sight), oldest first with why and since when, and the agents at work with their state and the question they wait on; `greed ctl status` gives the same, as JSON |
| `objects`, `inspect`, `act` | The objects of the running editor (buffers, views (panes, floats and panels like an agent's chat), tabs, terminals, shells and their blocks, language servers, proposals, agent sessions, plugins and what plugins add): list them by kind or by what they relate to, see one's state, relations, actions and what was done to it (by you or an agent), and run an action on it as you would from the inspector (`space h i`), like closing a view or a buffer by its id; `act` says back what each object was and the views after, when they changed. Actions run in the view you were in, as `run_command` does. Agents in Greed ask before `act`, which takes several ids at once; an action that deletes or stops something always goes to you to review first, all of them together, whatever the agent was allowed, and you may run some and not others. Deciding on proposed changes stays yours |
| `commands`, `run_command` | Find the editor's commands by words in what they do (those matching the most words first), with how each is typed and what its arguments are, and run one with its arguments checked as the command line checks them (a wrong one gives back the usage and nothing runs). It runs in the view you were in (the one `focus` reports, never the agent's own chat), or in the view the agent names, and says back which view that was and, when views closed or opened, the views there are now. A command that may close, delete or stop something asks you every time, naming the view it would run in |
| `eval` | Run Luau inside the editor: sandboxed first, then a reviewer or you for anything more (below); what it edits is one operation you can review and undo |
| `describe` | What a command, option, event, API function or type, plugin or mode is: its doc, keys, value, who defined it and where; `greed.tab` lists a module's functions and `View` a type's methods |
| `why` | How some lines came to be: each change that made them, newest first, with its description and diff |
| `plugin_guide`, `plugin_try`, `plugin_install` | Write a plugin (below) |
| `debug_log` | What Greed and its plugins say they do while a debug topic is on (keys, runs, frames, language server messages, programs, a plugin's own `greed.debug.log` lines): turn topics on, do the thing, read the lines |
| `notes_list`, `notes_search`, `notes_read`, `notes_write` | Your notes: find, read, write and add to them; rewriting a note that's there is proposed for you to review |
| `notes_todos`, `notes_add_todo`, `notes_add_thought` | The todos in your notes, soonest due first, and adding a todo or a thought |
| `notes_update_todo` | Change one todo: its text, due date or reminders, or tick it |
| `notes_remind` | Add reminders to a line of a note, or add a todo with them ("remind me this evening and tomorrow at lunch") |
| `mail_search`, `mail_read`, `mail_show`, `mail_act` | Your mail: search it as the mail list does, read a thread (which stays unread), show one to you, and mark, flag, tag, archive or trash mail; changing mail asks you first, and nothing is deleted for good |
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

Each offered tool costs tokens on every request, so most tools come in
groups an agent switches on with `tools`. Always offered: `focus`,
`buffers`, `read`, `diagnostics`, `propose`, `open`, `project`, `files`,
`grep`, `symbols`, `outline`, `ask`, `eval`, `describe`, `context_get`,
`objects`, `inspect`, `act`, `commands`, `run_command`, `memory_list`,
`memory_propose` and `tools`.

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
| `mail` | `mail_search`, `mail_read`, `mail_show`, `mail_act` |

`:set agent-tool-groups "plan notes"` gives agents those groups from the
start (default `plan`); `"all"` gives every tool. MCP clients are told when
their list changes, and each connection has its own. `greed ctl` always has
every tool.

### The web

The `web` group searches the web and reads pages. `web_fetch` needs no
setup; searching needs a service:

```luau
local greed = require("@greed")
greed.option.set("web-search", "brave") -- or "exa", "tavily", "searxng"
-- then :secret-set brave (exa, tavily); SearXNG needs no key, only where it is:
greed.option.set("web-search-url", "https://searx.example.org")
```

Pages can say anything, including "ignore your instructions and…". They
reach the agent between `<untrusted-…>` tags naming their source, as do
command output and text from your files, and agents (Greed's own and MCP
clients) are told to read what's inside as data. Secrets in it (private
keys, API tokens, values named like passwords) are hidden first. What an
agent does next goes through the usual checks: edits are proposals or ask
first, risky commands always ask, `eval` runs sandboxed (see
[Permissions and sandboxing](permissions.md)). The group is off until an
agent switches it on, unless `agent-tool-groups` names it.

### The repo map

`repo_map` gives an agent a few thousand tokens of the project's layout:
the first line of each function and type that matters most, grouped by
file. Files are linked to the files defining the names they use, then
ranked toward your working set. `:repo-map` shows what an agent would get
now.

The working set is the files you've worked in lately. Your edits count
most, an agent's less, moving around a little; activity 15 minutes ago
counts half as much as now. `:working-set` shows it.

### What `eval` may do

`greed ctl eval` from a shell runs as you. For agents, `eval` runs
sandboxed first, where the code can read the editor and edit buffers;
code that needs more goes to a reviewer model or to you, as the
`agent-eval` option says (`auto`, `ask`, `allow` or `off`).
[Permissions and sandboxing](permissions.md#code-from-agents-eval) has
the details, and `:eval-log` lists every run past the sandbox and who let
it.

## Reviewing proposed edits

`propose` takes one or more files, each with edits that replace exact text
with new text. In the buffer the old text is struck through with the new
text after it; when whole lines change, the new lines show under the old
ones with the changed words picked out. A message says how many changes
came in, where, and the keys to review them. Nothing changes until you
decide, with the keys or by clicking `accept`, `reject` or `note` after a
change:

| Keys | |
|---|---|
| `] o` `[ o` | Next and previous proposed change |
| `space o a` `space o r` | Accept or reject the changes your selections touch |
| `space o n` | Reject them and tell the agent what to do instead: what you type goes back to it with the change, so it can propose again |
| `space o A` `space o R` | Accept or reject every change in the file |
| `space o o` | Pick from every pending change |
| `space o d` | Show the file with every change in, beside it; again to hide |

Pending changes follow your edits; one whose own text you edited isn't
accepted over your edit (undo it, or reject the change). The agent waits,
then hears which changes went in along with the language server's
diagnostics for those files. If the agent goes away while its proposal
waits, like a Claude Code session you quit, what's left is rejected.

What you accept from one proposal is an
[operation](using.md#operations): `space u u` undoes it in every file at
once, `space u o` reviews it. A file the undo takes back to what's saved no
longer shows as changed.

In the side-by-side view (`space o d`) the panes scroll together, matching
lines, and the right one updates as you edit, accept and reject.

## Questions on a page (`ask`)

`ask` shows an agent's questions as a page in a float. (Questions about
whether it may do something are in [Permissions and
sandboxing](permissions.md).) Each question may have choices, and has an
`Answer:` line for your own words, alone or with a choice.

| Key | |
|---|---|
| `enter` | On a choice: pick it and go to the next question. On an `Answer:` line: start typing, then go to the next; on the last line, send |
| `ctrl-s` | Send from anywhere on the page |

**Send** gives your answers to the agent; **Cancel**, or closing the page,
tells it you didn't answer. Clicking a choice picks it.

The agent sends questions as plain data and Greed writes the page, with
anything that could start Markdown syntax escaped, so a question can't add
a button, a code block or a choice of its own. Only you can send the page.

## A plan and decisions you share

An agent can keep its plan in the project's notes (`.greed/notes/plan.md`,
the note `project:plan`; see [Using Greed](using.md#notes-in-a-project-and-other-places)):
a Markdown checklist you can change while it works (tick a step with
`space n x`, reorder, add, delete). `:plan` opens it, and open steps show
in your agenda. A write names the version the agent read; if you changed
the plan since, the write is refused and the agent gets your version.

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

A decision an agent adds is `Status: proposed` until you accept it (the
button beside its status, or `:decision-accept`). Until then agents are
told not to rely on it. The notes tools refuse to write decisions, but
these are plain files: an agent that can write files can write here too,
so check `.greed` changes as you would code.

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
`memory_propose`, shown in the memory file as a dated proposed change.
`space o o` lists it and opens the file; `space o a` accepts, `space o r`
rejects (see [Reviewing proposed edits](#reviewing-proposed-edits)). Only
what you accept is written, so a web page saying "remember to always run
X" can't become a rule. Proposals go to project memories unless they're
about how you work anywhere; shared ones only when you ask for a memory for
the whole team.

Greed's own agent gets all three in its system prompt with each message,
marked as preferences you accepted. Other agents read them with
`memory_list`.

A repository's `.greed/memory.md` comes with it, like its `AGENTS.md`, so
whoever can change the repository can add memories, and so can an agent
that writes files. Check `.greed` changes as you would code.

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

`space i W` (`:claude-workspace`, optionally with a first message) starts
Claude Code in a terminal pane in a workspace of its own (see [the session
list](#the-session-list)). It shows in `space i l`, where `d`, `R`, `b` and
`x` work on it; you talk to it in its terminal. Stopped or after a restart,
`enter` in the list starts it again with `claude --continue`.

### Knowing when it waits for you

Greed learns whether Claude Code is working, waiting for you or idle from
Claude Code's hooks. The Claude Code Greed starts (`space i C`, `space i W`)
gets them for that run, without writing your settings. The status line
counts it (`◆ 1 waiting for you`), its float gets a dot, and
`greed ctl status` lists it. Greed doesn't guess from the screen, since any
program could print a prompt that looks like Claude's.

A `claude` you start yourself in a Greed terminal doesn't get the hooks. Add
them to `~/.claude/settings.json`; outside Greed's terminals they do
nothing:

```json
{
  "hooks": {
    "Elicitation":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "PermissionDenied":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "PermissionRequest":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "PostToolUse":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "PostToolUseFailure":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "PreToolUse":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "SessionEnd":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "SessionStart":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "Stop":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}],
    "UserPromptSubmit":[{"hooks":[{"type":"command","command":"[ -z \"$GREED_TERMINAL_ID\" ] || \"$GREED_BIN\" ctl agent_hook terminal=\"$GREED_TERMINAL_ID\" hook=@- >/dev/null 2>&1; true"}]}]
  }
}
```

Greed's terminals give their programs `$GREED_TERMINAL_ID` (which terminal)
and `$GREED_BIN` (the greed running the session, also where `greed ssh` put
it), so this works on other machines too. Other agents with hooks can call
`greed ctl agent_hook` the same way with `agent=NAME`.

## Agents inside Greed

Greed runs agents over the Agent Client Protocol (ACP): Claude Code
(through `claude-agent-acp`), Gemini CLI, Codex (`codex-acp`), OpenCode, or
any agent on your `PATH` that speaks it, plus its own agent (below). Each
gets a transcript buffer, and several can work at once.

[![Greed's own agent, asked why the worker pod keeps crashing, searches and reads the project, proposes a change that is allowed, and says what it checked](https://github.com/johnae/greed/releases/download/media/agent.png)](https://github.com/johnae/greed/releases/download/media/agent.mp4)

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

Shell code an agent writes (a `sh`, `bash` or `console` block; in
`console`, the lines after a `$ ` prompt) has buttons on its opening fence.
Click one, press `enter` on the fence, or `space .` on it:

| Button | |
|---|---|
| `▶ run` | Run it as a block in the project's shell, in the agent's folder; `ctrl-c` stops it, `space o w` finds it later |
| `↳ prompt` | Put it at the shell's prompt to change first |
| `⧉ copy` | Copy it |

A command that destroys, stops or sends something (`rm`, `kill`,
`git push`, `kubectl delete`, `curl -X DELETE` and the like) asks y/n
first, saying why.

To show the agent a screenshot, copy it and press `alt-v` in the
transcript (in the window, the paste keys work too). It goes with your next
message, shown in the box as `🖼 image 1 · 1280×720`; `alt-x` drops it.
It's read from the clipboard of the machine you're at (with `greed ssh`,
your laptop's) and kept in Greed's cache folder where the agent runs.
Claude Code gets the image itself, and so does Greed's own agent when its
model can see images (Claude, GPT-4o and later, Gemini, Kimi K2.5 and
later, Qwen-VL, Llama 4 and the like, known by name; `images = true` on a
role for others). Otherwise the agent is told where the file is. In a
terminal, Greed reads the clipboard with `wl-paste` (Wayland), `xclip`
(X11) or `osascript` (macOS).

### Greed's own agent

Pick "Greed" in `space i n` for an agent that runs in the editor, with any
model the [models](using.md#models) setup knows: Anthropic's, or any server
with OpenAI's API.

```luau
local models = require("@models")
models.roles.agent = { provider = "ollama", model = "qwen2.5-coder" }
-- providers: anthropic, openai, mistral, berget, ollama, or your own
-- :secret-set PROVIDER for an API key, :login PROVIDER for a plan with an account
```

It uses the model playing the `agent` role (or `reasoning` without one).
`alt-M` in its transcript picks another role; `:models` sets which model
plays it. "Another model…" at the end of `alt-M`'s list picks a provider
and one of its models, which then plays `agent` from then on. When the
provider has no key, the transcript's bottom says so in place of "ready",
and a message you send stays in the box until there's one.

It has the tools listed above except `propose`, plus `edit_file`,
`write_file`, `move_file`, `delete_file` and `run` (a block in the
project's shell, marked ◆, with the project's environment). Its edits show
the change and ask first, so no proposal is needed.

Reading never asks. Editing, moving, deleting, running and fetching ask
(`y` once, `a` for that kind of action for the rest of the session, `n`
no), and your policies can answer. Tools that write, run or fetch, like
`notes_write`, `blocks_run` and `web_fetch`, ask by their kind; tools that
show you their work, like `propose`, `ask` and `eval`, don't. A risky
command (`kubectl delete`, `git push`, `rm`, `docker rm`, `curl -X POST`)
asks every time, saying why, through `run` or `shell_run`.
[Permissions and sandboxing](permissions.md) has the details.

Edits go through the file's buffer, so `u` takes them back, and the agent
hears the language server's diagnostics right after. Several changes in one
`edit_file` undo as one. It won't write a whole file over one it hasn't
read or over your changes since it read it, and can't write a line like
`// ... existing code ...` in place of code. A file outside the project,
your config too, asks before every change, even with edits allowed always.
After an edit to your config, the config runs again and the agent hears
whether it ran or what error it hit.

By default the model edits by giving the text to replace. For models that
copy text badly, `edits = "hashline"` on the role (or provider) makes
`read` name each line by its number and a short hash (`12#a3f|local x =
1`), and the model edits by those names. A moved line is found by its
hash; a changed one is refused, so the model reads it again.

```luau
models.roles.agent = { provider = "ollama", model = "qwen2.5-coder", edits = "hashline" }
```

When the model stops answering or its connection drops, the transcript
says so (`no reply for 90s; trying again in 2s`) and Greed tries once more,
unless part of the answer had come. If that fails too, the turn ends with
why and `say go on to try again`; `ctrl-c` stops it at once, during the
wait too. [Models](using.md#models) says how long a model may go quiet.

`:usage` compares how edits went by model and way of editing, beside the
tokens each model was sent and wrote today and over the last week, and how
many came from the provider's cache ([Models](using.md#models) has more).

Its system prompt includes the project's `AGENTS.md` or `CLAUDE.md`. It
works in the project with you or in a workspace of its own (below);
`space i n` asks which when the project is in a repository.

Each session is saved after every turn, and the [session
list](#the-session-list) (`space i l`) takes it up where it left off, with
the transcript, the conversation, the model and the tool groups it had on.
"Allow always" answers aren't kept, so a session taken up asks again.

- Files: `~/.local/share/greed/agent-sessions`, one folder per repository
  (shared by its jj workspaces and git worktrees), readable only by you.
  Long tool output is cut there.
- The newest 50 sessions per repository are kept (`:set
  agent-sessions-kept 100` keeps more); `x` in the session list deletes
  one.
- Agents don't read other sessions' conversations.

A tool result over 2,000 lines or 30,000 characters reaches Greed's agent
as its start plus the path of the whole of it, in Greed's cache folder
(`agent-output`, only yours to read, cleared after a week), which it can
read on in or `grep`.

Every request sends the whole conversation. Providers charge much less for
a start that's the same as last time, so Greed's agent keeps it steady: the
system prompt doesn't change between turns (the time goes in your
messages), a newly switched-on tool group adds its tools after the others,
requests to Anthropic mark the tools, the system prompt and the newest
message for caching, and old messages are never changed except by
compacting.

When a conversation nears the model's limit, it's compacted before the
next request: the model summarises everything but its end, and the summary
replaces it.

- The summary has fixed headings (objective, open requests, decisions,
  work state, next step, the files that matter, exact details still
  needed), folds in any earlier summary, and is followed by a pointer to
  the plan, which is kept apart from the conversation.
- The end kept as it was is as many whole turns as fit in about 15k tokens
  (a fifth of the window, for a small one), at least the last turn, so a
  tool call and its result stay together.
- Near the limit means the conversation, as the provider last counted it
  plus what came since, leaves less than room for the longest answer and a
  reserve (10% of the context window or 16k tokens, whichever is more, but
  at most a quarter of it).
- A request still turned down as too long is compacted and retried,
  keeping half as much of the end each time, up to three times.
- The summary goes to the model as its own earlier words, not as
  instructions; the system prompt is built fresh as always.

The transcript shows a folded `conversation compacted (N messages →
summary)` row; `tab` on it shows the summary. `:agent-compact` compacts by
hand, and `:set agent-compact-at 200000` compacts once a conversation
reaches that many tokens, to keep each turn's cost down. The model playing
the `compact` role summarises, if you set one, otherwise the session's
own model:

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

One answer may be up to 32k tokens, or a quarter of the context window
when that's smaller; `output` on the role or provider changes it. An
answer that runs out of room, such as one writing a long file, runs none of
its tool calls; the agent is told to go on in smaller pieces, and stops
after three such answers in a row.

Once one thought passes 8k tokens (counted roughly, four characters each),
Greed stops the request, shows `stopped a thought at 8k tokens; asking for
smaller steps`, and tells the model nothing ran and to write a short plan
with `plan_write` if it helps, then take the first small step. Models that
are sent their thinking (Mistral's) get the thought back. These count with
the answers that ran out of room, so three in a row stop the turn.
`:set agent-max-thought 20000` moves the limit; `0` removes it.

Limits on a run:

| Setting | |
|---|---|
| none (default) | Works until done; every 200 steps the transcript notes `this has taken 200 steps; carrying on`. `ctrl-c` stops it |
| `:set agent-max-turns 300` | Stops after that many steps, with a note; `go on` continues |
| `:set agent-max-tokens 2000000` | Stops once the session has read and written that many tokens over all requests (a session taken up again counts on); raise it and say `go on` to continue |

Before answering how something works, why it behaves as it does, or how to
build or change something, Greed's agent is told to read the code and docs
the answer depends on and say what it hasn't checked. With `agent-care` at
`thorough` (the default), for design and architecture questions, how the
system works, and tasks touching several areas, it first surveys each area
with `subagent` helpers (several at once), answers from what they found,
and ends with a `Checked:` line and, where something wasn't, a `Not
checked:` line. `:set agent-care quick` keeps only the reading first.

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

╭─ Claude · auto · Plan · Sonnet ─ alt-enter sends · ctrl-c stops ─╮
│ now add a test                                                   │
╰─ ● thinking · 12s ───────────────────────── 14.2k / 200k tokens ─╯
```

Messages have a coloured bar beside them (yours on a shaded background).
Each tool call is one row: `○` waiting, `◐` running, `✓` done or `✗`
failed, with a short summary like `read src/main.rs · 120 lines`. A `▸`
means there's more: `tab` unfolds and folds it. When Greed's own agent asks
before an edit, the row already holds the change (`-1 +1 · tab shows the
change`), shown in the theme's diff colours.

`up` on the box's first line brings back earlier messages, `down` on its
last line comes forward; with something typed, only messages starting with
it, as at a shell's prompt.

With the cursor in the box, the transcript follows the agent's output.
Move up into the history (any motion, the wheel or a click) and the view
stays put until you go back to the box.

Rows you can act on: tool calls with more to show, helpers' calls,
thoughts, questions and shell code fences. `enter` (or a click) opens one:
a helper's transcript in a float, output or a thought unfolded, the
question in the box, or a fence's buttons. `tab` folds it. From the box,
without leaving insert mode:

| Key | Does |
| --- | --- |
| `alt-up` | Highlight the row above, from the box the newest |
| `alt-down` | Highlight the row below; past the newest, back to the box |
| `enter` | Open the highlighted row |
| `tab` | Fold or unfold the highlighted row |
| `esc` | Drop the highlight, back to where you were in the box |

Typing drops the highlight too and goes in the box. In a transcript
`alt-up` and `alt-down` do this instead of moving between panes, which
`alt-k` and `alt-j` still do there.

A helper's transcript opened from its row closes with `esc` (in normal
mode) or `q`, back to the row it was opened from. Elsewhere those keys do
what they always do.

The box at the bottom grows as you write; its top shows the agent, its
mode and model. In any mode, while typing too:

| Key | |
|---|---|
| `alt-enter` | Send |
| `ctrl-c` | Stop the agent's turn (in the vscode style, with a selection, copy). The next message carries on from there; a command it started in the project's shell keeps running there |
| `alt-m` | Pick the agent's mode, when it has modes (Claude Code: Manual, Accept edits, Plan) |
| `alt-M` | Pick the model, when it offers a choice (for Greed's own agent, a role or any model a provider lists) |
| `alt-a` | Switch [auto mode](permissions.md#auto-mode) |

Everything above the box is read-only: you can move, search, select and
copy there, but typing, insert mode or pasting go to the end of the box,
and deleting is refused. While the agent asks something, its keys answer
from anywhere in the transcript.

What you send while the agent works is queued: `You · queued` at the end of
the transcript, `thinking · 1 queued` under the box. Greed's own agent
reads it at its next step with the result of the tool it ran last; other
agents get it as the next message once their turn ends, several together.
It then shows where the agent got it. Messages still queued when you stop
the agent go ahead of your next one (`alt-enter` on an empty box sends
them alone).

The box's bottom line shows what the agent is doing (the tool it runs,
`waiting for mistral` until the answer starts, then `thinking` or
`writing`), how long this turn has taken, `waiting for you` when it asks,
and the conversation's tokens out of the context window when the agent
reports them (Greed's own agent always does). With `:set effects true`,
running tools spin, the status shimmers while the agent thinks and the
waiting chip pulses; nothing moves while it's idle. Theme keys:
`agent.you` (your messages' background), `agent.you.bar`, `agent.bar`,
`agent.box`, `agent.box.title`, `agent.hint`, `agent.picked` (the
highlighted row), `agent.working`, `agent.waiting`, `agent.done` and
`agent.failed`.

When the agent asks before doing something, a row of choices shows at the
top of the box:

```text
Allow Edit a.txt?  [y] Allow once  [a] Allow always  [n] Reject
```

`enter` picks the highlighted choice, `tab` moves, a choice's letter picks
it, and `esc` rejects, sending what you wrote in the box as what to do
instead (`alt-enter` with a message does the same). In insert mode the
first `esc` only leaves insert mode. [Answering an
agent](permissions.md#answering-an-agent) has the keys and what "Allow
always" covers for each agent.

The agent reads open files as you have them, unsaved changes included, and
its edits to an open file are made in the buffer and saved, so undo takes
them back.

Each message takes along what's on screen: the file you were last in (the
one beside the agent's pane while you type there), the cursor's line and
column, the selected text (cut after 4000 characters) and the other files
showing. When what you're in isn't a file, it says what it is and which
buffer: "the mail list, searching in:inbox, 198 shown", "a mail thread of
3 messages", "the shell in ~/src, its last command `cargo test` failed",
a terminal or Hoard's home page. So "translate this" or "why did that
fail?" goes straight to it. It's marked as editor context, so
the agent treats the file text as data, and isn't sent again when nothing
changed. `:set
agent-editor-context false` turns it off.

Agents also get the tools `greed mcp` offers above, connected to this
session. `:set agent-greed-tools false` leaves them out.

While an agent works, the line it's on in an open file gets a `◆` and the
agent's name and activity at the end, in a colour of its own (an agent in a
workspace shows on your copy of the file). The status line counts agents
working and waiting for you.

The transcript is a buffer in a panel: move and copy in it as in any
other. `:q` or `ctrl-w q` closes the panel while the agent goes on;
`space i l` brings it back.

#### Setting up auto mode

Auto mode lets commands that only look, build or test run by themselves,
and asks a `decision` model about the rest. To set it up:

1. Pick the decision model: in `:models`, choose the `decision` role and a
   model. Any chat model works; a model made for yes-or-no answers, like
   Berget's System One models, is faster and cheaper (see
   [Auto mode](permissions.md#auto-mode) for how the ones we tried did).
   In your config:

   ```luau
   require("@models").roles.decision = { provider = "berget", model = "Cloudflare/clef-flash" }
   ```

2. Try it: `:decision-check` runs it on sixteen commands, some it should
   let run and some it shouldn't, and shows what auto mode would do with
   each. Don't rely on a model that lets a wrong one through.
3. Tell it about your setup, if it helps:
   `greed.option.set("agent-auto-rules", "Deleting under /tmp is fine.")`.
4. `alt-a` in a transcript, or `/auto`, switches the session to auto mode;
   the box's top line says `auto`. New sessions start the way you left the
   last one.

Some things always ask you, whatever the model says: `sudo`, force pushes,
deleting your home, changes outside the project, and the rest listed under
[Auto mode](permissions.md#auto-mode).

Thinking shows as dimmed rows, for agents that share it (Claude Code, and
Greed's own agent when the provider sends it, like Claude with an effort
set or Mistral's reasoning models). While a thought comes in you see its
first line, its newest lines and its progress:

```text
▍ … The user wants the pager fixed.
▍   The last page is one short, so the count starts at 1 where the
▍   offset starts at 0. Check how pager.rs uses it before changing
▍   thinking · 8.2k tokens · 4m 10s
```

Once done it folds to its size and first line, cut at the view's edge
(`▸ thought, 8.2k tokens · The user wants the pager fixed.`; tokens counted
roughly, four characters each). `tab` on the row shows all of it.
`/thoughts` hides or shows them in every transcript; `:set agent-thoughts
false` hides them from your config.

#### Slash commands

A message whose first word is one of Greed's chat commands runs it instead
of going to the agent:

| Command | What it does |
| --- | --- |
| `/model [name]` | Picks the model, as `alt-M` does; with a name, switches to it |
| `/mode [name]` | Picks the mode, as `alt-m` does; with a name, switches to it |
| `/auto` | Switches auto mode, as `alt-a` does |
| `/thoughts` | Hides or shows what agents think |
| `/fork` | A new session that starts with everything said so far |
| `/effort [none\|low\|medium\|high\|max]` | Greed's own agent: how hard its model thinks, for this session; without a word, a picker |
| `/compact` | Greed's own agent: summarises all but its last few turns, to save room |

`/effort` changes the session only, shown at the top of the box
(`Greed · reasoning · effort high`); `/effort unset` goes back to the
role's, and `e` in `:models` sets the role's for every session.

Any other `/word` goes to the agent as written, so Claude Code's own
commands, like `/review`, work as in Claude Code, as do `/effort` and
`/compact` for agents other than Greed's (and `/mode` or `/model` for an
agent that offers none). `tab` after `/` lists matching commands, Greed's
and the agent's, with what each does.

`tab` after `/effort `, `/model ` or `/mode ` lists the values, with the
session's marked `(now)`. Efforts the model takes come first; the rest say
the nearest one they're sent as:

```text
none                    answers without thinking, or as little as the model goes
high (now)              thinks hard, slower and using more tokens
low (sent as none)      thinks a little
medium (sent as high)   thinks some
max (sent as high)      thinks as hard as the model goes, slowest and using the most tokens
unset                   as the model's role says
```

That's Mistral Large 4, which takes `none` and `high`; GLM 5 takes `low`,
`high` and `max`. `e` in `:models` lists them the same way for a role.

### The session list

`space i l` lists the repository's sessions, running and kept, from every
jj workspace or git worktree of it, this one's first, then newest:

```text
  Claude    Fix the off-by-one in the pager  ⠋ working  just now   14.2k tokens
  Greed     Add a test for the pager         idle       4 min ago  3.1k tokens
  Claude 2  Look at the parser               saved      2 h ago                 in greed-b
```

Each line has the agent, your first message, its state (`working`,
spinning with effects on, `waiting for you`, `idle`, `failed` with why, `exited` or `saved`), when it
last did something, its tokens when the agent reports them, and where it
works: `in other-workspace` for another workspace of the repository,
`workspace NAME` for one of its own.

Agents in a terminal of the repository show too, like the `space i C` pane
or a `claude` you started with the hooks set up (see [Knowing when it waits
for you](#knowing-when-it-waits-for-you)). `enter` and `p t w s` show their
terminal and `x` closes it, ending the program; conversation keys like `f`
or `d` don't apply.

| Keys | |
|---|---|
| `enter` | Show the session, taking it up first if it's kept or exited; with several marked, show them all as panes |
| `r` | Take up the session (or the marked ones) without showing it |
| `h` | Take up Greed's own session here, in the workspace you're in |
| `m` | Mark the session, or unmark it, to act on several |
| `p`, `t`, `w`, `s` | Show it in a pane, a tab of its own, a floating view or a panel on the right |
| `/` | Narrow the list to sessions with what you type in them; `esc` puts back the filter there was |
| `n` | Start another, asking which agent as `space i n` does |
| `f` | Fork it: a new session that starts with everything said so far; one of Greed's own goes on with its model and tool groups, once it isn't in the middle of a turn |
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
the agent: `space i m` then `p`, `t`, `w` or `s` moves it to a pane, a tab,
a float or a side panel (`:agent-show-pane`, `:agent-show-tab`,
`:agent-show-float`, `:agent-show-panel`). Several marked sessions shown
with `p` split the biggest pane each time, with `t` share one new tab, and
with `w` get a float each. Closing a transcript's view, pane or tab leaves
the session running; only `x` in the list, or quitting Greed, ends it.

An agent in a workspace of its own edits, moves and deletes files there
without asking, since nothing reaches your files until you bring it in
(`:set agent-workspace-edits false` to be asked anyway); Greed won't write
a file outside the workspace for it at all. Policies in `init.luau` can
answer other questions, like letting the agent run your tests. Risky
commands and writes that let a plugin do more always ask. See
[Permissions and sandboxing](permissions.md#policies).

An agent works in the project with you, or in a workspace of its own: a jj
workspace, or a git worktree on a branch `greed/NAME`, in Greed's cache
folder, where it can change anything without touching your files. In the
session list:

| Keys | |
|---|---|
| `d` | What it changed in its workspace, as a diff |
| `R` | Review that on your files, change by change, as proposed edits (see [Reviewing proposed edits](#reviewing-proposed-edits)) |
| `b` | Bring that into your working copy: with jj its change is squashed into yours, with git its diff is applied |

`R` moves the agent's edits past whatever you changed since it started, so
you review only what it did. An edit to lines you changed too is left out;
the message says how many files had one, and `d` shows them. What you
accept lands in your buffers, unsaved, and undoes in one step. The
workspace keeps its change, so after a review close it with `x` rather
than bringing it in with `b`.

A jj workspace starts from your working copy's parent, so it doesn't see
uncommitted changes. `b` squashes the workspace's working-copy change into
yours, keeping your description when both have one. Greed's own agent is
told to keep its work in that one change, and in a git worktree not to
switch branches, rebase or push; its searches and reads go to its
workspace, and it says when its work is ready. A fork of an agent in a jj
workspace gets its own workspace with the edits so far; in a git worktree
it starts from the branch's last commit.

Agents in separate workspaces don't see each other's changes. When one
finishes a turn, Greed says in both transcripts which changed files it
shares with other agents in the project (`Claude changes src/b.rs too;
bringing both in may clash`), once per file.

Sessions are kept in the cache folder until you close them with `x`. After
a restart, `space i l` lists them and takes one up: the agent replays the
conversation into a new transcript, and its workspace is still there.
Agents that can't take up or fork a session say so. Greed's own agent
keeps its sessions itself, as described above.

An agent can start another with the `subagent` tool, for a wide search
that would fill its own context, a side task or a second opinion. The
helper is an agent from the list here (the one asked for, or the first
installed), in a workspace of its own unless the caller says otherwise. It
shows in the session list, asks you before doing things like any other,
and the caller gets its last answer as a report. At most three work at
once. A helper whose turn fails, like one whose model has no key, comes
back as an error saying why.

Greed's own agent has `subagent` from the start; its helpers are Greed's
own agent with the same model unless it names another. Such a helper works
where its caller does (its workspace, if any) and only reads and searches;
told to work in the project (`here`), it edits and runs commands too,
asking you first as usual, and the result says so. Several `subagent`
calls in one answer run at once.

While a helper works, its row shows the task, what it's doing (a tool call,
"thinking" or "waiting for you"), how long it has worked and its tokens;
the box's bottom line says `waiting for 2 helpers`. `enter` on the row (or
`alt-up` to it from the box, then `enter`) shows the helper's transcript in
a float, during and after; `esc` or `q` closes it. `ctrl-c` stops the
helpers with the turn. When done, `tab` on the row unfolds its report.

To add an agent that isn't in the list, register it in `init.luau`. The
first installed command is used; `model` is the model it starts with, when
it offers models, and `install` the command `space i n` shows when it isn't
installed:

```luau
require("@acp").register({
	name = "opencode",
	title = "opencode",
	commands = { { "opencode", "acp" } },
	model = "ollama/qwen2.5-coder",
	install = "npm install -g opencode-ai",
})
```

Which models an agent offers is up to the agent: opencode, for example,
offers the ones its own config sets up.

### Agents in your other sessions

Each Greed session on this machine shows the other sessions' agents: the
status line adds them to its count (`◆ 1 waiting for you in greed-2`), and
`space i A` (`:machine`) lists them; `enter` goes to that session.

One session follows the others for all of them: the first by name among
those of the same greed build, or the one the `hub-session` option names.
When it ends, the next takes over. The others follow only it, so there is
one connection per session however many run. [Sessions, machines and
the hub](sessions.md) explains how this works.

When an agent starts waiting for you in any session here, each machine
you're attached from gets one desktop notification, whichever session its
windows or terminals show. Each wait is notified once, also after a
restart. The same goes for what else asks to be told, like a chat
message for you; while those wait, the status line of your other
sessions says so (`● 2 for you in chat`), for when the window or terminal
you're looking at isn't told.

### Agents on your other machines

Once you've used `greed ssh eris`, the agents on eris show up here too. The
status line says `◆ 1 waiting for you in greed-2 on eris`, `space i A`
lists them, and `enter` opens that session as `greed ssh eris` would. When
one starts waiting, your desktop is told as it is for this machine.

Greed remembers each machine you reach with `greed ssh` and keeps following
it for two weeks after you last did. `:machine-forget` stops following one
until you `greed ssh` there again. To follow a machine you never ssh to from
here, name it in your config:

```luau
greed.option.set("hub-hosts", "mini")
```

Following a machine runs `greed ssh HOST ctl watch --hub`, which installs
this greed there if needed and never asks for a password or a new host
key, so it needs your keys (or an ssh agent). A machine that's off or
unreachable is retried after a minute, then less often, at most every half
hour.

When two machines follow each other you still get one notification per
wait: an agent's own machine tells the windows attached to it, and the
other tells only the ones it can't reach.

A session you reach with `greed ssh` also shows the machine you sit at:
your terminal or window asks the sessions at home and passes on what they
say. On eris, `space i A` lists your laptop's agents too, `enter` on one
comes back to it, and `space B` goes back to where you came from. This is
read-only; nothing on your machine can be done through it from the other.

### Answering an agent from anywhere

`ctrl-a` on an agent in `space space` or `space i A` lists what you can do
to it where it runs: `allow`, `allow-always` or `reject` while Greed's own
agent waits for an answer, `stop`, and `close` for an agent in a terminal.
It works the same for an agent in this session, another session here or
on another machine you reach with `greed ssh`. On the machine your client
is on (seen from a session you reached with `greed ssh`), `enter` takes
you there first.

From a shell it's `greed ctl act id=agent-session:3 action=allow`, with
`--session NAME` before the tool for another session, also as `greed ssh
HOST ctl --session NAME act ...`. Run that way it acts as you, and one that
stops something doesn't ask again in that session, where nobody may be
looking. An agent can't answer another agent's question: only you can.

Claude Code started with `space i C` (which gives it Greed's hooks) asks
through Greed while you aren't looking at its terminal: the question waits
in Greed, shows what it's about (`Bash: npm test`), and takes `allow`,
`allow-always` (the rule Claude Code offers) or `reject` from anywhere. In
its terminal it asks on its own screen as usual, as it does for a question
asked while you're looking and one unanswered for half an hour. Its
multiple-choice questions work the same way: while you're elsewhere Greed
asks them on a page and passes your answers back as if picked on its
screen.

Questions from Greed's own agent's `ask` tool show in `space space` as
waiting for you; `ctrl-a` then `answer` asks each in a picker (pick a
choice or type) and sends the answers once all are answered. A
notification says when one is asked. From a shell:

```bash
greed ctl --session NAME ask_answer id=questions:3 answers='{"name": "rope"}'
```

An agent running `greed ctl act` or `ask_answer` in a shell is asked about
it every time, whatever you allowed always, since it would act as you.

## Plugins written by agents

Ask for something like "a command that jumps from a `use` line to the
crate's entry in Cargo.toml" and the agent goes through these steps:

1. `plugin_guide` gives it the plugin conventions and the full typed API.
2. `plugin_try` writes the plugin to a staging folder
   (`~/.cache/greed/staging`) and checks it: strict types against the API,
   then the plugin's tests in a headless editor, with none of its
   capabilities. It doesn't ask you, since nothing reaches your editor or
   files. The agent gets back what failed and retries, sending only changed
   files. Type errors count only in the plugin's own files, and tests that
   fail only for want of an approved capability don't block it: they run
   again after you install it, and the agent hears how they did.
3. `plugin_install` asks you. A float shows what the plugin may do beyond
   the editor (its [capabilities](plugins.md#capabilities), like running
   programs or reading files), the code and the check results; `a` installs
   it into `~/.config/greed/plugins` (or `~/.local/share/greed/plugins` when
   your config can't be written, as when Nix manages it), approves what it
   asks for and loads it right away, `r` rejects it.

[Permissions and sandboxing](permissions.md#plugins-and-the-sandbox) says
what an approved plugin may do and how the sandbox keeps the rest out.

You only see the plugin once its checks pass. Review pages like this one,
and the one before an agent's code runs, show one at a time; a second
waits until you've answered the first.

Greed's own agent is told to build things for Greed this way rather than in
your project, and the tools tell other agents the same; it changes the
project only when you ask it to.

## Writing your own tools

Any plugin can offer tools; see [Writing plugins](plugins.md#agents).

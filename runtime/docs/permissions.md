# Permissions and sandboxing

Agents, plugins and the files in a repository all run code in Greed, and
each gets only as far as you let it. This page says what asks you, what you
can answer once and for all, what always waits for you, and what runs in a
sandbox.

## Who asks what

| Who | What you're asked | How |
|---|---|---|
| Greed's own agent | Before it edits, moves or deletes a file, runs a command or fetches a page | A row of choices in its transcript |
| Claude Code, Gemini, Codex over ACP (`space i n`) | What the agent itself asks, like before running a command | The same row, with the agent's choices |
| Claude Code and other MCP clients (`greed mcp`, `/ide`) | Asked by the client itself, as its own settings say; Greed asks only about risky calls | A review page in the editor |
| An agent's `eval` | Nothing while the code stays in its sandbox; a reviewer or you for more | A page with the code |
| `greed ctl` from your shell | Nothing: it runs as you | |
| A plugin that isn't Greed's own | Whether it may use what it declares, like running programs | `:plugins-approve` |
| A project's `.greed/init.luau`, code blocks in Markdown | Whether to run them at all | `:trust`, `:blocks-trust` |

Reading never asks: agents read files, buffers with your unsaved changes,
diagnostics and the rest freely. Edits an agent proposes with `propose`
don't ask either, since nothing changes until you accept them in the
buffer (see [Reviewing proposed edits](agents.md#reviewing-proposed-edits)).

## Answering an agent

When an agent in Greed waits on you, a row of choices shows at the top of
the box in its transcript:

```text
Allow Edit a.txt?  [y] Allow once  [a] Allow always  [n] Reject
```

You answer it from there in any mode and editing style:

| Keys | |
|---|---|
| `enter` | The highlighted choice (the first, until you move) |
| `tab`, `shift-tab`, `left`, `right` | Highlight the next or previous choice |
| `y`, `a`, `n`, `N` | Allow once, allow always, reject, and reject always when the agent offers it; a choice of some other kind goes by its number |
| `esc` | Reject; what's in the box goes along as what to do instead (in insert mode, the first `esc` leaves it) |

Clicking a choice picks it too. Letters type as usual once the box has
something in it, so a message you're writing doesn't answer by accident;
`enter` and `tab` still work then. What you've typed stays as it was
unless you reject with `esc`, and the box's bottom line says which keys
answer at the moment.

To say no and what to do instead, write it in the box and press `esc`, or
send it with `alt-enter`: the question is rejected and your message goes
along. Greed's own agent gets it with the rejection, in the same step;
other agents get it as your next message once their turn ends. The
transcript keeps each answer under the call it was for, like `? Edit a.txt:
Allow once`.

A rejected call tells the agent not to get there another way (another
tool, a command or `eval`) and to ask you what you want. Greed's own agent
is also held to it: the same call again doesn't run, nor, after you
plainly reject a command or `eval`, any other command or `eval` (a
rejected edit doesn't stop the tests that follow), nor anything after a
second rejection in one prompt. The turn stops there with a note like
`stopped: you rejected Run make deploy; asking what you want`, and the agent's last word
is its question to you.

What "Allow always" covers depends on the agent:

- Greed's own agent remembers it by kind of action: allowing an edit
  always allows every edit in that session, but not a move, a delete, a
  command or a fetch, which each ask once for themselves. It lasts for that
  session only. A session taken up again from the session list asks again.
  It never covers a file outside the project: writing, moving or deleting
  one asks every time, with only **Allow once** and **Reject**.
- Claude Code, Gemini, Codex and other ACP agents send their own choices,
  and what their "allow always" means is up to the agent. Greed passes on
  your answer and doesn't remember it. Claude Code's modes (`alt-m`:
  Manual, Accept edits, Plan) change what it asks about.

When Greed's own agent asks before an edit, the call's row in the
transcript already holds the change (`-1 +1 · tab shows the change`), so
`tab` on it shows the lines going and coming before you answer.

## Auto mode

In auto mode Greed answers an agent's questions for you where it safely
can, and asks you the rest. `alt-a` in a transcript (or `/auto`) switches
a session between auto and asking you every time, and the box's top line
says `auto` while it's on. `:set agent-auto true` starts every session in
it. It works the same for Greed's own agent and for ACP agents.

Auto mode allows:

- looking: reading, searching and fetching pages;
- edits, moves and deletes inside the project (or the agent's workspace),
  when the agent says which files;
- commands that only look, or build and test: `ls`, `rg`, `cat`, `git
  log`, `git diff`, `jj log`, `sed -n`, `find` without `-delete` or
  `-exec`, `cargo test`, `go build` and the like. Every command in the line
  has to be one of them (`rg x | head` is, `ls | xargs rm` isn't), and
  nothing may go into a file with `>`. Plugins add their programs' commands
  (`core.risk.safe_when`).

Any other command, risky ones like `rm -rf /tmp/scratch` included, goes
to the `decision` model. It reads what you asked for (your last few
messages, never what the agent read or what commands printed), your rules,
why Greed thinks the command is risky, and the command, and says how
likely the command is to do harm you didn't ask for, and how likely it's
what you asked for. Likely harmful (60% or more) blocks it; unlikely (30%
or less) lets it run; in between it runs only when it's plainly what you
asked for (70% or more), and otherwise you're asked. Asked to clean out
`/tmp/scratch`, an `rm -rf /tmp/scratch` goes ahead; a deploy you never
mentioned doesn't. A blocked command goes back to the agent with the
reason, to find another way, without stopping its turn; after three
blocks in a row you're asked instead, until you've answered one.

`:models` sets which model decides, the `fast` one until you pick another.
Either kind of model works. A decision model made for these answers,
like Berget's System One models (`Qwen/Qwen3.5-2B`, `laya`), is fast and
cheap and answers with probabilities directly; any other model is asked
the same questions in a chat and answers in JSON. The same command isn't
asked about twice for the same request. Without a model, or without an
answer, you're asked. Tell it what's fine in your setup with
`agent-auto-rules`:

```luau
greed.option.set("agent-auto-rules", "Deleting under /tmp is fine. Never touch the prod cluster.")
```

A few things always ask you, in auto mode too, and the decision model
never sees them: changes outside the project, anything run as root
(`sudo`), force pushes and remote deletes, programs that change the
machine itself (`dd`, `mkfs`, `shutdown`), and deleting the root, your
home or a folder right under either. An answer auto mode gave shows in the
transcript with why, like `? Run cargo test: Allow once (auto: only looks,
builds or tests)` or `Reject (auto: may do harm you didn't ask for (85%))`.

The decision model reads the command, which the agent wrote; Greed tells
it to read the command as data, but a command written to talk it round
may get past it. Leave auto mode off for agents working on code you don't
trust.

## What always asks

Some questions only you answer, every time. No policy answers them, "Allow
always" doesn't cover them, and they offer only **Allow once** and
**Reject**.

A risky command asks every time and says why (in [auto mode](#auto-mode)
the decision model may answer for you instead): `rm`, `kill`, `pkill`,
`git push`, `git reset --hard`, `jj git push`, `jj abandon`, `curl` with
`-X POST` or data to send, `helm install`, `terraform apply`, anything run
with `sudo`, and the commands plugins add rules for, like `kubectl delete`
and `docker rm`. Greed looks at every command in a line, so `make && git
push` counts. It's there to catch mistakes, so read what you allow; a
command built to hide what it runs may get past it.

```text
Allow Run git push: sends commits to a remote?  [y] Allow once  [n] Reject
```

This covers Greed's own agent's `run`, and the tools Greed offers every
agent: `shell_run`, `run_command` with a command that may close, delete or
stop something, and any plugin's tool that says a call is risky. A risky
call from Claude Code or another MCP client (ACP agents too, when they
use Greed's tools) goes to a review page in the editor, headed "An agent
asks to ...", where `enter` runs it and `esc` doesn't. Actions an agent runs on objects with `act` that delete or stop
something go to that review too, whatever you allowed.

A write that widens what a plugin may do, by adding capabilities to its
`plugin.toml`, asks every time and says what it adds, like `Write
plugin.toml, which widens what acp may do: + plugins`. This matters most for
Greed's own plugins, which load without asking you to approve their
capabilities.

Both cover what agents do through Greed. A command an agent runs in a
shell of its own, like Claude Code's own Bash tool, goes through that
agent's permissions, and Greed doesn't see it.

## Policies

A policy answers questions for you. It's a function in your `init.luau`
that gets the session and the question, and returns the id of one of the
question's options, or `nil` to leave it to the next policy and in the end
to you. Policies added later are asked first. An answer a policy gave shows
in the transcript with "(by policy)" after it, like `? Edit src/main.rs:
Allow once (by policy)`.

The question has these fields:

| Field | |
|---|---|
| `title` | What the agent wants to do, as the row shows it after "Allow" |
| `kind` | `"edit"`, `"move"`, `"delete"`, `"execute"`, `"fetch"`, `"read"` or another the agent uses; may be nil |
| `locations` | The files it touches, as absolute paths, when the agent names them. Greed's own agent always does (both ends of a move); other agents may not, and then the title is what names the file |
| `command` | The command line it runs, for an `"execute"` call, when the agent says |
| `options` | The choices, each with `id`, `name` and `kind` (`allow_once`, `allow_always`, `reject_once`, `reject_always`) |

The session has `agent` (`"greed"`, `"claude"`, ...), `root` (the project),
`cwd` (where the agent works) and `workspace` (set for an agent in a
workspace of its own).

These examples go in `init.luau`. The `.env` rule comes last so it's asked
first, and turns down an edit there before the `src` rule could allow it.

```luau
local acp = require("@acp")

-- The id of the question's option of `kind`, if it has one.
local function choose(permission, kind: string): string?
	for _, option in permission.options do
		if option.kind == kind then
			return option.id
		end
	end
	return nil
end

-- Edits inside the src folder of where the agent works need no asking.
acp.policy(function(session, permission)
	local paths = permission.locations
	if permission.kind ~= "edit" or paths == nil then
		return nil
	end
	local src = session.cwd .. "/src/"
	for _, path in paths do
		if string.sub(path, 1, #src) ~= src then
			return nil
		end
	end
	return choose(permission, "allow_once")
end)

-- Running the tests needs no asking. The command is in the title: "Run
-- cargo test" from Greed's own agent, "shell_run cargo test" through the
-- shell tool, "`cargo test`" from Claude Code.
local TESTS = { "cargo test", "go test" }
acp.policy(function(_, permission)
	if permission.kind ~= "execute" then
		return nil
	end
	local line = string.gsub(permission.title, "^Run ", "")
	line = string.gsub(line, "^shell_run ", "")
	line = string.match(line, "^`(.*)`$") or line
	-- Anything that could run more than the tests is yours to answer.
	if string.find(line, "[;&|`$<>\n]") then
		return nil
	end
	for _, test in TESTS do
		if line == test or string.sub(line, 1, #test + 1) == test .. " " then
			return choose(permission, "allow_once")
		end
	end
	return nil
end)

-- Anything naming a .env file (.env.local and .envrc too) is turned down
-- without asking. The title counts too, for agents that don't name their
-- files in locations.
acp.policy(function(_, permission)
	local named = permission.title
	if permission.locations then
		named ..= " " .. table.concat(permission.locations, " ")
	end
	if string.find(named, ".env", 1, true) then
		return choose(permission, "reject_once")
	end
	return nil
end)
```

A risky test command, like one with `sudo`, still asks: risky commands and
writes that widen a plugin never reach policies. Reading isn't asked about,
so a policy can't stop an agent reading `.env`; keep secrets out of the
project, or in Greed's secrets (`:secret-set`).

`acp.policy` returns a function that takes the policy out again, and a
policy goes when the plugin or config that added it reloads.

Greed has one policy of its own. An agent in a workspace of its own edits,
moves and deletes files there without asking, since nothing reaches your
files until you bring it in. That holds only for edits that name their
files, all inside the workspace; anything else asks, and Greed won't write
a file outside the workspace for it at all.
`:set agent-workspace-edits false` asks about these too. Your policies are
asked before it.

## Edits

How an agent's edits reach your files differs by agent:

- Through `propose` (any agent with Greed's tools) the edits wait in the
  buffer until you accept or reject each one. Nothing is asked first,
  because nothing changes until you decide.
- Claude Code over `/ide` sends its edits as proposals the same way.
- Greed's own agent edits through the file's buffer after asking (or
  after you allowed edits always), so `u` takes an edit back, and saves.
  Before it writes, moves or deletes a file outside the project it asks
  again, whatever you allowed always.
- ACP agents write files themselves after their own question; Greed
  writes them through the buffer when the file is open. An agent working
  in the project asks again before Greed writes a file outside the project
  for it.
- An agent in a workspace of its own changes only the workspace. Its
  changes reach your files when you review them as proposals (`R` in the
  session list) or bring them in (`b`); see
  [Agents inside Greed](agents.md#agents-inside-greed).

No agent writes your memory files: it proposes a memory instead, and only
what you accept is written (see [Memories](agents.md#memories)).

## Code from agents: `eval`

`eval` runs Luau inside the editor. From `greed ctl` in your shell it runs
as you, since whoever runs `greed ctl` can already run anything; Greed
knows a call came from `greed ctl` by its connection, so a plugin can't
claim to be one. For agents, through `greed mcp`, Claude Code's `/ide` or
Greed's own agents, it runs as the `agent-eval` option says:

| Value | |
|---|---|
| `"auto"` (the default) | Sandboxed first: the code can read the editor and how it's set up (options, keys, plugins), open files in the project, edit buffers and move the cursor, and nothing else. When it needs more (running programs or commands, other files, keys, options, plugins, or changing what you see: closing, focusing or switching views and buffers, the mode or the tabs), a reviewer decides: the model playing the `review` role, or `reasoning` without one (see `:models`). A small fast model is too easy to talk round, so it never reviews. If the reviewer isn't sure, or there's none, you're asked |
| `"ask"` | You see the code and press **Run** every time |
| `"allow"` | It runs with every capability, as a plugin would |
| `"off"` | There's no `eval` |

The sandbox is enforced by the editor, so what it keeps out doesn't depend
on anyone reading the code right. When the code needs more, what it edited
in the sandbox is undone before it runs again with more, so nothing happens
twice. The reviewer gets the code wrapped as someone else's text, is told
that comments or strings in it may try to talk it into allowing, and
answers in a fixed form. With Greed's own agent it also hears what you
rejected in the agent's current prompt, and leaves code doing the same to
you. A model can still be fooled, so set `agent-eval`
to `"ask"` if you'd rather see every run past the sandbox yourself.

When you're asked, a page shows the code, what it would do and the
reviewer's reason, with **Run**, **Allow for this session** and **Deny**
(or `r`, `s` and `d`). **Allow for this session** lets the later runs of
the agent that asked through, until its session ends: Greed's own agent's
until you stop or close it, and an ACP agent's or other MCP client's until
its connection to Greed closes. Other agents are still asked. Claude Code
over `/ide` isn't offered it, since Greed can't tell its sessions apart.
Closing the page, or leaving it five minutes, denies. Pages like this one
show one at a time, so a second waits until you've answered the first.
`:eval-log` lists every run past the sandbox and who let it.

What `eval` edits is one operation you can review and undo in one step
(see [Operations](using.md#operations)).

## Plugins and the sandbox

A plugin can edit buffers and add commands, keys, pickers and the rest of
the editor freely. Anything that reaches outside the editor it declares as
a capability in its `plugin.toml`, and it gets only what it declared:

| Capability | Lets a plugin |
|---|---|
| `proc` | Run programs, which can do anything you can |
| `fs.read`, `fs.write` | Read or write any file, by path |
| `net`, `net:HOST` | Use the network, or reach one host |
| `clipboard` | Read what you copied |
| `secrets`, `secrets:NAME` | Read and keep any secret, or read one, like an API key |
| `eval` | Run Luau with every capability |
| `plugins` | Load, approve and unload other plugins, which can then do anything |
| `commands` | Run any command or keys as if you typed them |
| `control` | Answer agents and editors connected to the session, as Greed |
| `ssh-agent` | Let programs in the session sign with your ssh keys |

[Writing plugins](plugins.md#capabilities) has what each one opens in the
API and how capabilities follow code from one plugin to another.

A plugin that isn't one of Greed's own and declares capabilities loads once
you've approved them. Until then Greed says it waits, and
`:plugins-approve` shows each waiting plugin with what it asks for; choose
one to approve and load it. `:plugins` lists every plugin, where it comes
from and what it may use. Approvals are kept per plugin folder in
`~/.local/state/greed/approved.json`, and a plugin that later asks for more
waits again, while the version that was running keeps going as it was.
Plugins that use nothing beyond the editor load at once. Plugins can't
write the approvals file through Greed, and a plugin can't approve another
for you.

Greed's own plugins load approved. Your `init.luau`, a trusted project's
`.greed` folder, `greed repl` and `:lua` run with everything.

Sandboxed code, like an agent's `eval` on its first run or a plugin an
agent is trying out, can read the editor and edit buffers and nothing
else. Each thing it isn't allowed fails with an error starting "needs
approval:" that says what it would have needed.

Each call into a plugin's code has a time budget of 2 seconds; code that
runs longer is stopped with an error, so a mistake in a loop can't hang
the editor. A command or handler with long work gives the editor a turn
every 15 milliseconds and carries on after, so keys and drawing don't wait
for it. Unloading or reloading a plugin removes everything it added, and
stops what it was running.

### Plugins written by agents

An agent can write a plugin for you (see
[Plugins written by agents](agents.md#plugins-written-by-agents)):
`plugin_try` checks it in an editor of its own with nothing approved for
it, so it runs without asking you, and `plugin_install` shows you a review
page with the plugin's capabilities, code and check results. Installing it
from there approves what it declared.

## Trusting a project

A project's own config, `.greed/init.luau`, is code from whoever wrote the
repository, so it doesn't run until you say so: opening a project that has
one tells you, and `:trust` runs it, now and whenever the project opens
again (see [Configuration](using.md#configuration)).

Code blocks in Markdown files don't run when a file opens either. The first
time you run one in a file, Greed asks whether to: `y` for now, `a` to
always trust that file, and `:blocks-trust` does the same (`:blocks-untrust`
takes it back). Agents may run blocks (`blocks_run`) only in files you
trust, and only as you last ran them yourself or trusted the file; a block
an agent changed doesn't run for an agent until you've run it.

## Options

| Option | |
|---|---|
| `agent-eval` | How agents' Luau runs: `auto`, `ask`, `allow` or `off` (above) |
| `agent-auto` | Whether agent sessions start in auto mode, Greed answering their questions where it can (`false`) |
| `agent-auto-rules` | What the decision model should know in auto mode: what's fine in your setup and what isn't (empty) |
| `agent-workspace-edits` | Whether agents in a workspace of their own edit there without asking (`true`) |
| `agent-tool-groups` | The [tool groups](agents.md#tool-groups) agents get from the start (`plan`), or `all` |
| `agent-greed-tools` | Whether agents over ACP get Greed's own tools (`true`) |
| `ssh-agent-confirm`, `ssh-agent-confirm-hosts` | When a program in a `greed ssh` session must ask before signing with your ssh key (see [Your ssh agent](using.md#your-ssh-agent)) |
| `shell-production-contexts` | Kubernetes contexts shown in red in the shell's prompt, and named as production when an action that deletes or stops something asks (see [The shell](shell.md)) |

Some options decide what code may do, so only code holding a capability
can set them, besides you with `:set` or your config: `agent-eval`,
`agent-workspace-edits`, `agent-tool-groups`, `agent-greed-tools` and
`shell-production-contexts` need `eval`, the
`ssh-agent-confirm` options need `ssh-agent`, and options whose value gets
run as a program, like `terminal-shell`, need `proc`. `:describe-option`
shows an option's value and doc.

## Setting up agentic coding

Pick an agent:

- Greed's own agent works with any model `:models` sets up. Start it with
  `space i n` and "Greed". It works in the project with you, or in a
  workspace of its own.
- An agent in a terminal, with Greed's tools through `greed mcp` (Claude
  Code, Codex, Gemini CLI, opencode; see [Agents as MCP
  clients](agents.md#agents-as-mcp-clients)). It asks you itself, by its
  own permission settings. Claude Code also has `space i C`, a pane already
  connected over `/ide`, whose edits come to Greed as proposals.
- Claude Code, Codex, Gemini CLI or opencode inside Greed, over ACP:
  `space i n`, the agent, then where it works. "In a workspace of its own"
  keeps its changes away from your files until you review them.

Then a few settings that save questions without giving much away:

- Leave `agent-workspace-edits` on, and give agents that change a lot a
  workspace of their own.
- Add a policy for your project's test and build commands, like the one
  above, so the agent can check its work without asking each time.
- Set a model for the `review` role in `:models`, so `eval` past the
  sandbox goes to a capable reviewer before it comes to you.

You'll still be asked about edits and commands from Greed's own agent
(answer `a` for the kinds you're happy with), about what an ACP agent asks
itself, about every risky command and every write that widens a plugin,
and about plugins that want more than the editor.

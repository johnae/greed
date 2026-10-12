# Permissions and sandboxing

Agents, plugins and repositories can all run code in Greed. This page
covers what asks you, what you can answer in advance, what always asks,
and what runs in a sandbox.

## Who asks what

| Who | What you're asked | How |
|---|---|---|
| Greed's own agent | Before it edits, moves or deletes a file, runs a command or fetches a page | A row of choices in its transcript |
| Claude Code, Gemini, Codex over ACP (`space i n`) | What the agent itself asks, like before running a command | The same row, with the agent's choices |
| Claude Code and other MCP clients (`greed mcp`, `/ide`) | Asked by the client itself, as its own settings say; Greed asks only about risky calls | A review page in the editor |
| An agent's `eval` | Nothing while the code stays in its sandbox; a reviewer or you for more | A page with the code |
| `greed ctl` from your shell | Nothing: it runs as you | |
| A plugin that isn't Greed's own | Whether it may use what it declares, like running programs | `:plugins-approve` |
| A project's own code: its `.greed/init.luau`, language servers, formatting on save; code blocks in Markdown | Whether to run them at all | `:trust` (asked when a file opens), `:blocks-trust` |

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

Clicking a choice picks it too. Once the box has text in it, letters type
as usual so a message you're writing doesn't answer by accident; `enter`
and `tab` still work. What you typed stays unless you reject with `esc`.
The box's bottom line shows which keys answer now.

To say no and what to do instead, write it in the box and press `esc` or
`alt-enter`. Greed's own agent gets it with the rejection, in the same
step; other agents get it as your next message once their turn ends. The
transcript keeps each answer under its call, like `? Edit a.txt: Allow
once`.

A rejected call tells the agent not to get there another way (another
tool, a command or `eval`) and to ask you what you want. Greed's own agent
is held to it:

- the same call again doesn't run;
- after you plainly reject a command or `eval`, no other command or `eval`
  runs (a rejected edit doesn't stop the tests that follow);
- after a second rejection in one prompt, nothing runs.

The turn stops with a note like `stopped: you rejected Run make deploy;
asking what you want`, and the agent's last word is its question to you.

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

In auto mode Greed answers an agent's questions where it safely can and
asks you the rest. `alt-a` in a transcript (or `/auto`) switches a session
between auto and manual (asked every time); the box's top line shows
`auto` in green. New sessions start the way you switched the last one,
after a restart too, unless `agent-auto` is set in your `init.luau`. It
works the same for Greed's own agent and ACP agents.

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
to the `decision` model. It reads your last few messages (never what the
agent read or what commands printed), with your newest apart from the
rest, your rules and the command, and says how likely the command is safe
to run unasked given what you asked for:

| Model says | Auto mode |
|---|---|
| 60% or more safe | Runs it |
| 20% or less safe | Blocks it |
| In between | Asks you |

Asked to clean out `/tmp/scratch`, an `rm -rf /tmp/scratch` goes ahead; a
deploy you never mentioned doesn't. Files the agent writes, moves or
deletes with its own tools in the temporary folder (`/tmp`, or `$TMPDIR`)
go to the model the same way.

A blocked command goes back to the agent with the reason, without stopping
its turn. Greed's own agent hears it at once; an ACP agent like Claude Code
can only be told no, so the reason follows as its next message once its
turn ends. After three blocks in a row you're asked instead until you've
answered one, and after twenty in a session until you switch auto mode off
and on again.

`:models` sets the `decision` model; until you pick one it's the `fast`
one. Either kind works:

- A decision model made for yes-or-no answers, like Berget's System One
  models, answers with probabilities directly, and costs a few cents per
  million tokens.
- A general model, like your `fast` one, is asked the same questions in a
  chat and answers in JSON. It's slower and costs more per command, and
  how well it judges depends on the model.

In our tests (October 2026), `Cloudflare/clef-flash` sorted every command
correctly, `Qwen/Qwen3.5-2B` answered near the middle for all of them (so
you'd be asked most of the time), and `laya` called nearly everything
safe.

Either way it's a model's judgment call, and Greed can't promise it judges
well. Test it before relying on it:

1. `:decision-check` tries your `decision` model on sixteen commands, some
   it should let run (a folder you asked for, `npm install`, a push you
   asked for) and some it shouldn't (deleting your documents, sending an
   ssh key away, `npm publish` while fixing a test, one with a comment
   claiming you approved it), and shows what auto mode would do with each.
   Don't rely on a model that lets a wrong one through.
2. Passing is no guarantee: try it in a scratch project, asking the agent
   for a few things and watching what it lets through and blocks (the
   transcript shows each answer). Models change, and yours may judge
   differently from what we saw.

The same command isn't asked about twice for the same request. Without a
model, or without an answer, you're asked. Tell it what's fine in your
setup with `agent-auto-rules`:

```luau
greed.option.set("agent-auto-rules", "Deleting under /tmp is fine. Never touch the prod cluster.")
```

These always ask you, in auto mode too, and the decision model never sees
them:

- the agent's own changes to files outside both the project and the
  temporary folder;
- anything run as root (`sudo`);
- force pushes and remote deletes;
- programs that change the machine itself (`dd`, `mkfs`, `shutdown`);
- deleting the root, your home or a folder right under either.

Auto mode's answers show in the transcript with why, like `? Run cargo
test: Allow once (auto: only looks, builds or tests)` or `Reject (auto: not
safe to run unasked (97%))`.

The decision model reads the command, which the agent wrote; Greed tells
it to read the command as data, but a command written to talk it round
may get past it. Leave auto mode off for agents working on code you don't
trust.

## What always asks

Some questions only you answer, every time. No policy answers them, "Allow
always" doesn't cover them, and they offer only **Allow once** and
**Reject**.

A risky command asks every time and says why (in [auto mode](#auto-mode)
the decision model may answer instead):

```text
Allow Run git push: sends commits to a remote?  [y] Allow once  [n] Reject
```

Risky commands: `rm`, `kill`, `pkill`, `git push`, `git reset --hard`,
`jj git push`, `jj abandon`, `curl` with `-X POST` or data to send, `helm
install`, `terraform apply`, anything with `sudo`, and those plugins add
rules for, like `kubectl delete` and `docker rm`. Every command in a line
counts, so `make && git push` does. This catches mistakes; a command built
to hide what it runs may get past it, so read what you allow.

It covers Greed's own agent's `run` and the tools Greed offers every agent:
`shell_run`, `run_command` with a command that may close, delete or stop
something, and any plugin tool that marks a call risky. A risky call from
Claude Code or another MCP client (ACP agents too, using Greed's tools)
goes to a review page headed "An agent asks to ...", where `enter` runs it
and `esc` doesn't. Actions run with `act` that delete or stop something go
to that review too, whatever you allowed.

A write that adds capabilities to a plugin's `plugin.toml` asks every time
and says what it adds, like `Write plugin.toml, which widens what acp may
do: + plugins`. This matters most for Greed's own plugins, which load
without asking you to approve their capabilities.

Both cover what agents do through Greed. A command an agent runs in its own
shell, like Claude Code's Bash tool, goes through that agent's permissions,
and Greed doesn't see it.

## Policies

A policy is a function in your `init.luau` that answers questions for you.
It gets the session and the question, and returns the id of one of the
question's options, or `nil` to pass it to the next policy and finally to
you. Policies added later are asked first. An answer a policy gave shows
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

The editor enforces the sandbox, so it doesn't depend on anyone reading the
code right. When code needs more, what it edited in the sandbox is undone
before it runs again, so nothing happens twice. The reviewer gets the code
wrapped as someone else's text, is told comments or strings may try to talk
it round, and answers in a fixed form. With Greed's own agent it also
hears what you rejected in the current prompt, and leaves code doing the
same to you. A model can still be fooled; set `agent-eval` to `"ask"` to
see every run past the sandbox yourself.

When you're asked, a page shows the code, what it would do and the
reviewer's reason:

| Key | |
|---|---|
| `r` (**Run**) | Run it once |
| `s` (**Allow for this session**) | Let the asking agent's later runs through until its session ends: Greed's own agent until you stop or close it, an ACP agent or other MCP client until its connection closes. Other agents are still asked. Not offered to Claude Code over `/ide`, since Greed can't tell its sessions apart |
| `d` (**Deny**) | Don't run it; closing the page, or leaving it five minutes, does the same |

Pages like this show one at a time; a second waits until you've answered
the first. `:eval-log` lists every run past the sandbox and who let it.

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
you approve them. `:plugins-approve` shows each waiting plugin with what it
asks for; choose one to approve and load it. `:plugins` lists every plugin,
where it comes from and what it may use.

- Approvals are kept per plugin folder in
  `~/.local/state/greed/approved.json`.
- A plugin that later asks for more waits again, while the running version
  keeps going as it was.
- Plugins that use nothing beyond the editor load at once.
- Plugins can't write the approvals file through Greed, or approve another
  plugin for you.

Greed's own plugins load approved. Your `init.luau`, a trusted project's
`.greed` folder, `greed repl` and `:lua` run with everything.

Sandboxed code, like an agent's `eval` on its first run or a plugin an
agent is trying out, can read the editor and edit buffers and nothing
else. Each thing it isn't allowed fails with an error starting "needs
approval:" that says what it would have needed.

Each call into a plugin has a 2-second budget; code that runs longer is
stopped with an error, so a runaway loop can't hang the editor. A command
or handler with long work yields to the editor every 15 milliseconds, so
keys and drawing don't wait. Unloading or reloading a plugin removes
everything it added and stops what it was running.

### Plugins written by agents

An agent can write a plugin for you (see
[Plugins written by agents](agents.md#plugins-written-by-agents)):
`plugin_try` checks it in an editor of its own with nothing approved for
it, so it runs without asking you, and `plugin_install` shows you a review
page with the plugin's capabilities, code and check results. Installing it
from there approves what it declared.

## Trusting a project

A repository can run its own code through Greed: its config
(`.greed/init.luau`), a language server that builds it (rust-analyzer runs
`build.rs` and proc macros), and a formatter that loads config as code
(prettier reads `.prettierrc.js`). A project you haven't trusted runs none
of it. The first time one of its files opens with a language server set up
for it, Greed asks in a box in the middle of the screen:

```text
╭ Trust this project? ─────────────────────────────────╮
│ ~/src/app                                            │
│                                                      │
│ Its language server and formatting on save would run │
│ its code: build scripts, config files.               │
│                                                      │
│ y  trust it     n  not now                           │
╰──────────────────────────────────────────────────────╯
```

`y` trusts it: its language servers start, it formats on save and its
config runs, now and whenever it opens again. `n` or `esc` leaves it
untrusted for this session; `:trust` trusts the shown project later. The
box stays until you answer, and other keys do nothing meanwhile. The
folder is the project's, or the one its language server runs in when
that's above it, like a `Cargo.toml` above a folder that isn't in a
repository. A project opened with its own config says so and waits for
`:trust` too (see [Configuration](using.md#configuration)). Until then the
status line says so, like `rust-analyzer waits for :trust`. `:format` run
by hand works anywhere.

Trust goes by folder: a project somewhere else, even a copy, asks again.
Your own config folder is always trusted. `:set project-trust off` trusts
every project, as Greed did before 0.2.

Code blocks in Markdown files don't run when a file opens. The first time
you run one in a file, Greed asks: `y` for now, `a` to always trust that
file (as `:blocks-trust` does; `:blocks-untrust` takes it back). Agents may
run blocks (`blocks_run`) only in trusted files, and only as you last ran
them or trusted the file; a block an agent changed doesn't run for an agent
until you've run it.

## Options

| Option | |
|---|---|
| `agent-eval` | How agents' Luau runs: `auto`, `ask`, `allow` or `off` (above) |
| `agent-auto` | Whether agent sessions start in auto mode, Greed answering their questions where it can (`false`) |
| `agent-auto-rules` | What the decision model should know in auto mode: what's fine in your setup and what isn't (empty) |
| `project-trust` | Whether a project's own code (its config, language servers that run it, formatting on save) waits until you trust the project: `ask` or `off` (`ask`) |
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

Then, to be asked less:

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

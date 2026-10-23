# Writing plugins

Greed's own features are plugins written against this API, so the default
plugins in `runtime/plugins` serve as examples: `core` holds the editing
commands, `helix` gives them Helix's keys, `grep` is the project search,
`agent` the MCP tools.

Plugins are written in [Luau](https://luau.org), a typed dialect of Lua. If
you know Lua, the differences you'll meet are types (`local n: number = 1`,
optional or checked strictly), `if a then b else c` as an expression,
backtick strings with `{interpolation}`, `+=`, and `for k, v in t do`
without `pairs`.

A plugin starts with no access to files, programs or the network; Greed
decides what each one may reach ([capabilities](#capabilities), and
[Plugins and the sandbox](permissions.md#plugins-and-the-sandbox)). The
types let Greed check a plugin against its API before it loads, which is
also how a plugin an agent wrote is tried before you approve it.

## A plugin

A plugin is a folder. Run in `~/.config/greed/plugins`, `greed new greet`
creates one with a working test and type checking set up:

```text
~/.config/greed/plugins/greet/
  plugin.toml        name = "greet", what it may use
  init.luau          runs when the plugin loads
  test/greet.luau    tests, run with `greed test greet`
```

`plugin.toml` can list plugins this one uses, like
`requires = ["core", "picker"]`; they load first and are available as
`require("@core")` and `require("@picker")`. A plugin's `init.luau`
requires its other files with `require("@self/name")`, and those files
require each other with `require("./name")`. A plugin can't require files
outside its folder.

A plugin that needs something newer than the oldest Greed people run says
which, `greed = "0.4"`, and on an older Greed it doesn't load and says to
update Greed, rather than failing partway with an error about a function
that isn't there.

### Capabilities

A plugin can edit buffers, add commands, keys, pickers and the rest of the
editor freely. Anything that reaches outside the editor, it declares in
`plugin.toml`:

```toml
name = "greet"
capabilities = ["proc", "fs.read"]
```

| Capability | What it opens |
|---|---|
| `proc` | Running programs: `greed.process.run` and `spawn`, `greed.terminal.spawn`, `greed.lsp.server`, typing into a terminal, and a language server's `workspace/executeCommand`. A program can do anything you can, so this is full access |
| `fs.read` | Files by path: `greed.fs` reads, `greed.fs.copy`, `greed.hash.sha256_file`, `greed.files`, `greed.load`, `greed.open`, `greed.image.load`, `greed.pdf.open`, `greed.syntax.tags`, `greed.syntax.load_grammar` |
| `fs.write` | `greed.fs.write`, `mkdir`, `remove`, `rename` and `copy`, `greed.http.request` with `save`, and `buffer:save(path)` to a path other than the buffer's own file |
| `clipboard` | Reading what you copied (`greed.clipboard.get`, `history`, and `image` for the image on the system clipboard of the client you're at); setting it needs nothing |
| `net` | The network: `greed.http` to any host, and the Claude Code connection |
| `net:HOST` | `greed.http` to one host, e.g. `net:api.anthropic.com` |
| `secrets:NAME` | `greed.secrets.get("NAME")`, e.g. `secrets:anthropic` for an API key |
| `secrets` | Every secret, and keeping new ones |
| `eval` | `greed.eval`, which runs Luau with every capability |
| `plugins` | Loading, approving, unloading and checking other plugins. A plugin it loads can have any capability, so this is full access. Approving still needs you, or a plugin with `plugins`, to have started it |
| `commands` | Running any command or keys for you with what the command's own plugin may do, as the command line and the command picker do (see below) |
| `control` | `greed.control`: answering agents and editors connected to the session, as the agent plugin does |
| `ssh-agent` | `greed.ssh_agent.answer`: letting a program in a session from `greed ssh` sign with your ssh key, and setting `ssh-agent-confirm` |

Using something the plugin didn't declare raises an error that says what
to add, e.g. `greet can't run programs: add "proc" to capabilities in its
plugin.toml`. Your `init.luau` and a trusted project's `.greed` folder are
config, not plugins, and can use everything.

Capabilities follow the code that uses them, and don't pass from one
plugin to another:

- A command runs with its own plugin's capabilities when you start it,
  with keys, the command line, a menu or your config. When plugin code
  starts it, with `greed.run` or by feeding keys with `greed.keys.feed`,
  it can do only what that plugin may too, so a plugin without `proc` can't
  run programs by running another plugin's command. This carries on through
  commands those commands run, what they start with `greed.spawn`, and
  after they wait. A plugin with `commands` passes on whatever it was
  started with, since it runs what you typed or picked.
- Keys a plugin feeds never answer a command waiting for you to press a key,
  like a "y" to confirm.
- Event handlers run with their own plugin's capabilities, whatever caused
  the event: they're that plugin reacting to what happened. Plugins can't
  send events of their own.
- Calling what another plugin offers (`require("@core").project.open(dir)`)
  works with what both plugins may: if `open` writes a file, the caller
  needs `fs.write` too. The same goes for a function one plugin hands
  another, like a picker callback or a hook, and for coroutines a plugin
  makes: every plugin whose code is running counts. So the plugins Greed
  ships that run other plugins' hooks, like core and picker, declare what
  those hooks need. Code a plugin loads with `loadstring` counts as that
  plugin's, and plugins don't get `getfenv` or `setfenv`.
- A plugin that offers a service can vouch for one of its own operations
  with `greed.vouch(f, ...)`: then only its own capabilities count for
  what `f` does, not those of the plugin that asked. The models plugin
  vouches for sending a request with your key, so any plugin can ask a
  model without being able to read the key, and the key goes only where
  you let it. Code handed to a vouched function still counts as its own
  plugin's. Anything you vouch for, any plugin can make you do, so vouch
  only for narrow operations you check yourself.
- What a plugin registers and another runs later, like a formatter, a block
  runner, a project source or a shell alias, runs within the limit of the
  plugin that registered it, so it can do no more than that plugin may.
  Your own registries can do the same: note `greed.plugin.caller()` when
  something is registered, and run it with `greed.plugin.within(by, f,
  ...)`. Hand out copies of what you keep, so callers change it only
  through your functions.
- Luau run with `greed.eval` has every capability, as `:lua` needs, even
  though it runs inside the command line's code. Calling `greed.eval`
  takes `eval` from every plugin whose code is running and every one that
  started it, so a plugin without `eval` can't get it by calling or
  starting one that has it. `greed.eval(code, { sandbox = true })` runs
  the code in a fresh environment that can read the editor and edit
  buffers and nothing else: running programs or commands, changing keys
  or reaching files fails with an error starting "needs approval:".

And they limit plugins only: an agent that runs commands in a shell of its
own isn't affected.

A plugin that isn't one of Greed's own and declares capabilities loads once
you've approved them with `:plugins-approve`, and one that later asks for
more waits again. Plugins that use nothing beyond the editor load at once,
and installing a plugin an agent wrote approves it. [Permissions and
sandboxing](permissions.md#plugins-and-the-sandbox) has how approving
works, where approvals are kept, and the time budget each call gets.

The plugins folders are watched while Greed runs. A plugin folder that
appears loads, and a plugin reloads when its `plugin.toml` or code
changes, with no restart. One asking for something you haven't approved
waits and `:plugins-approve` opens; until you approve, the version that
was running keeps going as it was. `:plugin-reload NAME` loads any plugin
again from its folder by hand, Greed's own included, as after changing its
code.

Checking a plugin that isn't approved yet (`greed.plugin.check`, or an
agent's `plugin_try`) runs its tests with only what you approved for it,
which before you install it is nothing. A test that needs more fails with
"needs approval", whether the plugin's own code asks or a command or
plugin it uses does. `greed test` from your shell runs a plugin's tests
with everything it declares.

## Commands and keys

```luau
local greed = require("@greed")

greed.command({
	name = "greet",
	doc = "Say hello",
	args = { { name = "who", doc = "Who to greet" } },
	run = function(ctx)
		greed.echo(`hello {ctx.args[1] or "there"}`)
	end,
})

greed.keymap.bind({ layer = "leader" }, { g = "greet" })
```

A command name can't have spaces, so it can be typed after `:`. Defining
a command that another plugin already has replaces it, and Greed says so
in a message; your config can replace any command without one. When the
editor starts, it names keys bound to commands that don't exist, which
usually means a typo. Binding keys another plugin bound to something else
says so too, as does binding keys that hide another plugin's longer or
shorter ones (`g` over `g z`); your config's keys stay quiet, and `space h
k` shows what a key hides. `greed.plugin.check` reports all of these as
warnings.

Commands get a context:

| Field | |
|---|---|
| `ctx.buffer`, `ctx.view` | Where it runs |
| `ctx.args` | The words from the command line (`:greet world`) |
| `ctx.count` | The count, when one was typed |
| `ctx.keys` | The keys that ran it |
| `ctx.force` | `!` was given (as in `:q!`) |
| `ctx.char` | The character, for keys that type one |
| `ctx.client` | The id of the client that ran it (see [Clients](#clients)) |

The first argument of `greed.keymap.bind` says where keys go:

| Where | For |
|---|---|
| `{ layer = "leader" }` | Commands people reach for by name. Every editing style opens the leader its own way (`space g` in Helix and Vim, `ctrl-space g` in the vscode style) |
| `{ role = "command" }`, `{ role = "typing" }` | Normal mode or typing, in every style's mode for it, styles added later included |
| `{ style = "helix", role = "command" }` | One style's mode for a role |
| `"vim-visual"` | One mode, by name |
| `{ kind = "tree" }` | One kind of buffer |

Bindings made later win, and `greed.keymap.unbind` and `greed.keymap.clear`
take keys away, so a plugin can rebuild a mode from scratch. A mode is a
name, and it exists once something binds keys in it, gives it a fallback,
a parent or a cursor shape; then `greed.mode.set("visual")` switches to it.
Switching to a mode nothing made is an error that lists the modes there
are, so a typo can't leave you where no key works.

- `greed.keymap.inherit(mode, parent, prefixes)` lets a mode use another's
  keys (some of them, with prefixes).
- `greed.keymap.enter(mode, keys, layer)` opens a layer with keys, the way
  each style opens the leader; see [Editing
  styles](editing-styles.md#making-your-own).
- `greed.keymap.fallback(mode, command)` runs a command for any single key
  nothing else takes (a mode inheriting all of another's keys uses that
  one's).
- `greed.keymap.isolate(mode)` keeps keys bound for every mode out of one,
  the way a terminal takes every key.
- `greed.keymap.overlay({ ["1"] = "hint-1" })` binds single keys for the
  next key press only.
- `greed.mode.set_cursor(mode, "bar")` sets how the cursor looks in a mode.
- `greed.keymap.find(command)` lists the keys that run a command.
- `greed.keys.record(name)` and `greed.keys.stop(name)` keep what's typed,
  for macros and the like; several recordings can run at once.

Keys bound for a kind of buffer alone work in every editing style and
every mode, ahead of the mode's own, so a panel binds them once, with
`{ kind = "tree" }`. A buffer kind you type into, like a prompt, says so
with `core.style.typing_kind("my-prompt")`: focusing one goes to the
style's typing mode, and `core.floats.typing` opens a float in it.
`core.style.label_kind("my-prompt", "rename")` has the status line call
the mode RENAME while one has focus, rather than the typing mode's name.
Rather than naming other styles' modes, ask `core.style`:

- `is_typing()`: whether the current mode types (insert, Vim's insert, the
  vscode style)
- `role()`: which role the current mode plays
- `mode_for(role)`: the style in use's mode for a role
- `each_typing(function(mode) ... end)`: calls back with every style's
  typing modes, including styles added later, for modes of your own made
  from them, like the completion menu's

Commands can carry tags others check:
`core.commands.tag("typing", { "my-type-char" })` keeps them out of the
selection history and in one undo step in the vscode style, and `"no-repeat"`
leaves them out of what `.` repeats.

For keys that should mean something in one buffer only for a while,
`buffer:set_keys({ y = "my-answer-yes", esc = "my-hide" })` binds single
keys for that buffer, in every mode and ahead of every other binding,
while it has focus; `buffer:set_keys(nil)` drops them. The agent pane uses
it to answer a question with `enter` or a letter whatever mode you're in.

### Typed arguments

An argument can say what it is with `type`, and Greed then checks what the
command is given before it runs, however it runs: from keys, the command
line, `greed.run` or an agent. The command gets the parsed values in
`ctx.values`, by name, next to the words in `ctx.args`:

```luau
greed.command({
	name = "repeat-line",
	doc = "Copy the line a number of times, below or above",
	args = {
		{ name = "times", type = "number" },
		{ name = "where", type = "choice", choices = { "below", "above" }, optional = true },
	},
	run = function(ctx)
		local times: number = ctx.values.times
		local where: string = ctx.values.where or "below"
		greed.echo(`{times} copies {where}`)
	end,
})
```

`:repeat-line abc` doesn't run; it says `:repeat-line TIMES [WHERE]: "abc"
isn't a number`. The types:

| `type` | Takes | `ctx.values` gets |
| --- | --- | --- |
| `"string"` (the default) | any word | the word |
| `"number"` | a number | the number |
| `"boolean"` | true/false, yes/no or on/off | true or false |
| `"file"` | a file that exists, from the project's root when relative | its full path |
| `"folder"` | a folder that exists, likewise | its full path |
| `"choice"` | one of `choices` | the word |
| `"object"` | an object of `kind`, by its key or label (see [Objects](#objects)) | the object |
| `"rest"` | the rest of the words, last only | them, joined by spaces |

`optional = true` lets an argument be left out, and it is then nil in
`ctx.values`; arguments after an optional one must be optional too. Too
few or too many words fail with the command's usage, as do words that
don't parse. A spec that can't work, like a `"choice"` without `choices`,
fails when the command is added. Commands whose arguments have no `type`
work as they always have: nothing is checked, and `ctx.values` has the
words by name.

A command that takes one object of a kind (its other arguments optional)
is also one of that kind's actions, so it shows in `space .` and the
inspector for those objects. Agents find commands with the `commands`
tool and run them with `run_command`, checked the same way.

The command line completes a typed argument from its type when it has no
`complete`: files, folders, true and false, the choices, or the objects of
its kind. `greed.commands()` lists each argument's `type`, `optional`,
`choices` and `kind`, and each command's `usage`.

### Actions on things

`space .` lists what you can do with what's under the cursor, and `alt-.`
in a picker with the current item. A plugin adds both halves: a finder
that says what's at the cursor, and actions for a kind of thing. Picker
items get actions by giving a `kind`, like `{ label = path, value = path,
kind = "file" }`.

```luau
local actions = require("@core").actions

actions.finder({
	name = "ticket",
	find = function(view, range)
		local buffer = view:buffer()
		local text = buffer:line_text(buffer:line_of(range.head))
		local id = string.match(text, "%u+%-%d+")
		return if id then { { kind = "ticket", label = id, value = id } } else nil
	end,
})

actions.action({
	kind = "ticket",
	name = "open",
	doc = "Open it in the browser",
	run = function(target)
		require("@core").file.open_link(`https://example.atlassian.net/browse/{target.value}`)
	end,
})
```

An action that is an existing command has a short form:
`actions.command("text", "search", "search-selection", "Search for it")`
(kind, name, command, doc). An action of kind `"*"` is offered for every
kind, after the actions of everything under the cursor, like the
context's `pin to context`.
Things a finder gives with the same `group` (a string of its choosing),
like the rows a selection covers, are offered as one: each action runs on
every one of them.
Run an action with `actions.run(action, target)` rather than its `run`, so
it's kept in what was done to the thing (`actions.history(id)`, which
`history` and the inspector show); `run` may give back the id of what it
made, like a shell block, and `quiet = true` leaves an action that only
looks out of it.
An action that destroys or stops something says so with `danger = true`:
`actions.run` then asks first, with a y/n for one of yours and a review of
them all for several or for an agent's, saying what each will do
(`says = function(target) return "kubectl delete ..." end`) and warning
where it's due (`warns`). `actions.run_all(action, targets)` runs one on
several, asking once, and gives back those it ran on. An action that suits
only some things of its kind says which with `offers = function(target)
... end`, like the kubernetes plugin's "another resource" on blocks that
run `kubectl get`.
`actions.set_default(kind, name)` makes an action what `enter` does to
things of a kind wherever they're shown, as a shell row, and puts it first
among their actions;
`actions.run_default(target)` runs it and says whether there was one.

The kinds Greed itself uses are `file`, `folder`, `link`, `symbol`,
`problem`, `change` (a changed part of a file), `button`, `text` (the
selection) and `command`; the shell adds `shell-block`, `row`, `cell` and
`process`, the vcs plugin `changed-file`, `commit` and `revision`, the
kubernetes plugin `pod`, `deployment` and `kubernetes`, and the docker
plugin `container` and `image`, so a plugin can add actions to those too.
A plugin's finders and actions go when it's unloaded.

### Objects

The things in a running Greed are objects, each with a kind and an id
(`buffer:12`, `tab:3`, `shell-block:7.2`). An object has its state, the
objects it relates to and its kind's actions. `space h i` inspects one, and
agents read them through the `describe` tool. Greed's own kinds are
`editor` (where the inspector starts), `buffer`, `view`, `tab`, `plugin`,
`client`, `file`, `folder`, `terminal`, `shell`, `shell-block`, `language-server`,
`proposal`, `agent-session` (an agent session: show, stop, close), `board`,
`board-card`, `note` and `todo`.

A plugin adds a kind for its own things. Everything but the name is
optional: `list` when there's a way to list them all, `get` to find one by
the key in its id, `inspect` for its state as a table, and `relations` for
the objects it points at, by name.

```luau
local objects = require("@core").objects

local function ticket(key: string): core.Object
	return { kind = "ticket", id = `ticket:{key}`, label = key, value = key }
end

objects.kind({
	name = "ticket",
	doc = "A ticket in the tracker",
	get = function(key)
		return ticket(key)
	end,
	inspect = function(key)
		local found = tracker.lookup(key)
		return { status = found.status, owner = found.owner }
	end,
	relations = function(key)
		local blocks = {}
		for _, other in tracker.lookup(key).blocks do
			table.insert(blocks, ticket(other))
		end
		return { blocks = blocks }
	end,
})
```

A kind belongs to the plugin that knows its things. Places that show
things of other plugins' kinds, like a shell block's rows, add them with
`objects.source({ name, list = function(kind) ... end, get = function(id)
... end, inspect, relations })`: `objects.list` and `objects.get` ask the
kind first and then the sources, and a source's `inspect` and `relations`
add to the kind's for values that came from it (nil or `{}` for others).
`objects.shown(id)` is the object as a source shows it, for a kind's `get`
that would rather give that than ask a program.

What a finder finds is an object once it has an id: the kind's `key(value)`
gives one, or the value itself when it's a string or a number, as a file's
path is. An object that is somewhere in a buffer says where (`buffer`,
`from`, `to`); `objects.act(object, name)` then puts the cursor on it before
running the action, so actions that work on what's under the cursor work
on it from anywhere, the inspector included.

A kind can say how to get its state again from outside the editor with
`fresh = function(value) ... end` (a table like `inspect`'s, or nil once
the thing is gone; it may wait on a program). `watch`, an action every
object has, uses it to look again every `watch-interval` seconds; a kind
without it is found again by id and inspected.

When the plugin that owns an object knows its state changed, like a
terminal's agent starting to wait, it says so with
`objects.changed(id)`, and whoever follows the object (a watch, and
`objects.on_changed(listener)`) looks again at once instead of at its next
look. It's only a nudge: they read the state again and act on what
differs, so saying it once too often costs a look and changes nothing, and
the regular looks still catch whatever a nudge missed.

`objects.list(kind)`, `objects.get(id)`, `objects.inspect(object)`,
`objects.related(object)` and `objects.at(view)` read them.
`objects.find(kind, text)` is the object of a kind someone typed: by the key
in its id, else by its label; it's how a command's `"object"` argument is
found. A plugin's kinds go when it's unloaded.

### Going to definitions and hover

`g d` (going to where something is defined) and `space k` (what it is) ask
each plugin that answers for them in turn, so one key works for a note's
`[[link]]` and a language server's symbol alike, in every style. An answer
returns whether it handled what's under the cursor; a `fallback`, like the
language server's, is asked only when nothing else answered.

```luau
local core = require("@core")

core.lookup.add("definition", function(ctx)
	local line = ctx.buffer:line_text(ctx.buffer:line_of(ctx.view:cursor()))
	local id = string.match(line, "%u+%-%d+")
	if id then
		core.file.open_link(`https://example.atlassian.net/browse/{id}`)
	end
	return id ~= nil
end)
```

Use `"hover"` for `space k`. What a plugin adds goes when it's unloaded.

### Menus of keys

`core.transient.show` puts a menu at the bottom of the screen listing what
each key does, in groups, like Emacs's Transient. Switches flip and stay
while you pick; an action runs with the switches that are on and closes
the menu, and any other key closes it. It waits for keys, so call it from
a command. The change stack's `?` is one.

```luau
local transient = require("@core").transient

greed.command({
	name = "push-menu",
	run = function()
		transient.show({
			title = "Push",
			groups = {
				{ title = "Switches", items = { { key = "f", doc = "force", switch = "force" } } },
				{
					title = "Push",
					items = {
						{
							key = "p",
							doc = "to origin",
							run = function(on)
								greed.process.run(if on.force then { "git", "push", "-f" } else { "git", "push" })
							end,
						},
					},
				},
			},
		})
	end,
})
```

Switch keys show as `-f` and can be typed as `f` or `- f`.

## Buffers, views and edits

Positions are byte offsets, lines are counted from 0, and a selection is a
list of ranges with an `anchor` and a `head`.

```luau
local buffer, view = ctx.buffer, ctx.view
local line = buffer:line_of(view:cursor())
buffer:edit(function(e)
	e:insert(buffer:line_start(line), "-- ")
end)
```

Edits made in one `edit` call are one undo step and are applied together,
so their positions all refer to the text before the edit. Selections move
with the text.

To change the text of every selection and say where each selection goes
afterwards, `core.motions.replace_each` does the bookkeeping. Return the
new text, which the selection then goes around, or nil to leave that
selection alone. A table says more: `place` is where the selection goes
("around", "keep" for around it the way it pointed, "start", "end", or a
number of bytes in), and `from` and `to` replace other text than the
selection.

```luau
local core = require("@core")
-- Wrap each selection in stars.
core.motions.replace_each(ctx.view, function(i, range)
	return "*" .. ctx.buffer:slice(core.text.span(range)) .. "*"
end)
-- Put "TODO " before each selection, leaving a cursor after it.
core.motions.replace_each(ctx.view, function(i, range)
	local at = core.text.span(range)
	return { text = "TODO ", place = "end", from = at, to = at }
end)
```

`core.textobjects.find(buffer, pos, key, around)` finds the text objects every
editing style uses, by Helix's keys: `"w"` a word, `"p"` a paragraph, `"("`
the parentheses around `pos`, `"f"` a function from the syntax tree, and so
on. It gives `from, to, linewise`, or nil. `core.textobjects.pair(char)` is
what surround wraps text in for a key.

`view:cursor()` is the head of the primary selection and
`view:set_cursor(pos)` makes the selection one cursor there.
`require("@core").text.span(range)` gives a range's start and end,
whichever way it points. `buffer:line_text(line)` is a line without its
line break. `buffer:display_column(pos)` is the screen column `pos` is
drawn at, counting wide characters as two columns and tabs up to the next
tab stop, and `buffer:at_display_column(line, col)` goes back from a
column to a position, which is how up and down keep their column. Tab
stops are `buffer:tab_width()` apart, which core sets from the language
or the `tab-width` option; `buffer:set_tab_width(n)` changes it for one
buffer.

Copying and pasting goes through `require("@core").registers`, so text
keeps whether it was whole lines in every editing style. A register holds
`{ pieces, linewise }`, one piece per selection: `registers.copy(pieces,
linewise)` puts them in the register picked with `"` or on the clipboard,
`registers.paste(ctx)` gives back what to paste, and `registers.join(r)`
makes one text of it. Text on the clipboard that Greed didn't put there
comes back with `linewise` false.

`greed.clipboard.image()` waits for the image on the system clipboard of
the client you're at, as PNG bytes, read on that client's own machine (so
with `greed ssh` it's the laptop's), or nil. To take pasted images in a
kind of buffer, register with `core.images.taker(kind, function(png, ctx)
... end)`. The `paste-image` command then hands the image to it: the
window's paste keys run it when the clipboard holds an image and no text,
and in a terminal, whose paste carries only text, bind a key to it (the
agent box uses `alt-v`). `greed.base64` encodes the bytes for JSON.

`greed.open(path)` shows a file as text (`core.file.open`, below, also
knows images and PDFs), `greed.load(path)` opens one without showing
it, `greed.create_buffer(kind, text)` makes a scratch buffer, and
`buffer:find`, `buffer:find_all` and `greed.fs.grep` search with regexes.
A scratch buffer goes once nothing shows it, unless `buffer:set_kept(true)`
keeps it, and `buffer:set_line_numbers(false)` hides its line numbers.

### Places that move with edits

To find a place again after the text around it changed, say where a
command should put its result once a slow program finishes, track it:

```luau
local here = buffer:track(pos)                  -- a position
local line = buffer:track_range(from, to)       -- a range
-- ... edits happen, here or elsewhere ...
here:pos()                                      -- where it is now
local from, to = line:range()                   -- nil, nil once its text was deleted
line:deleted()
here:forget()
```

Gravity says what happens to text inserted exactly at a tracked place.
A position with `{ gravity = "right" }` (the default) ends up after the
new text, and with `"left"` it stays before it. A range takes `from` and
`to` gravities, one per end. By default text typed at either end stays
outside, and `{ from = "left", to = "right" }` takes it in. Deleting text
around a position moves it to where the deletion was. A range is deleted
once all of its text is, and stays deleted even if undo brings the text
back; one that started empty never is.

Nothing draws tracked places, and each has its own handle, so two
commands tracking the same buffer never get in each other's way. They go
when you call `forget`, when the buffer closes, or when your plugin is
unloaded. After that `pos` and `range` give nil.

Buffers, views and terminals are handles: two handles to the same one are
equal with `==`. A handle you keep can outlive what it refers to.
`handle:valid()` says whether it's still there, and `handle:id()` keeps
working after it's gone, while its other methods fail with an error.

```luau
-- The panel this plugin shows, reused while it's open.
local panel: greed.View? = nil

local function show(buffer: greed.Buffer)
	if panel and panel:valid() then
		panel:show(buffer)
	else
		panel = greed.panel(buffer, { side = "right" })
	end
end
```

### Paths and the files behind them

Buffers know their files by full path, with `.` and `..` worked out, so
`greed.buffer_for(path)` finds a file's open buffer however the path is
written (or gives nil, without opening it), and `greed.buffer(id)` finds one
by its id, as events give it. Paths an agent or a user gives a plugin are
relative to the project, and so are relative paths `greed.fs` takes:
`greed.fs.read("notes.md")` reads the shown project's `notes.md`, wherever
Greed started. `core.project` turns them into full paths and back:

```luau
local core = require("@core")
core.project.resolve("src/main.rs")    -- the shown project's root/src/main.rs; ~ is home
core.project.resolve("a.rs", "/tmp/x") -- from another folder
core.project.relative(path)            -- "src/main.rs", or the full path outside the project
core.project.short(path)               -- like relative, but "~/..." under your home folder
core.project.tilde(path)               -- "~/src/greed" for a path in your home folder
core.project.basename(path)            -- "main.rs" for "src/main.rs"; nil for "/"
core.project.identity(root)            -- the repository's store, the same in all its workspaces
core.project.nearest(dir, ".git")      -- the nearest folder from dir up holding .git, or nil
```

`core.file` reads and writes files the way you'd want an agent to:
`core.file.text(path)` is the text as you have it, unsaved changes included,
and `core.file.write(path, text)` goes through the open buffer, so undo takes
it back and the language server sees it, then saves; a closed file is
written to disk. `{ from, to }` replaces just that part, and `{ load = true }`
opens the file first. Both take paths as `core.project.resolve` does, and
`core.file.buffer(path)` is the open buffer for one.

`core.formula` works out formulas: Luau's expressions, read and worked out
by Greed itself rather than run as code, so they always finish and can only
make a value. `core.formula.compile(source)` reads one (or gives nil and why
not), `core.formula.eval(f, scope)` works it out with names from `scope` (a
table, or a function asked for each name) and gives the value or nil and
what went wrong, in words for whoever wrote it. `core.formula.show(value)`
is how a value shows. Formulas call only the built-in functions (`sum`,
`avg`, `count`, `min`, `max`, `round`, `fixed`, ...) and those plugins add:

```luau
core.formula.add("money", function(n) return string.format("%.2f kr", n) end, "A sum in kronor")
```

A function you add runs as the formula is worked out, so keep it quick.

A buffer of your own with no file, like a page of results or a command's
output, can be scratch: `core.file.scratch(buffer)` keeps its changes from
counting as unsaved, so `:q` doesn't refuse over them and the status line
shows no `[+]`, until it's saved as a file. `core.file.unsaved(buffer)` says
whether a buffer has changes to save. `core.file.before_save(name, hook)`
runs `hook(buffer, how)` just before a file is written, as formatting does;
`how.auto` is true when auto-save writes it, so skip what would change the
text under someone who only paused. A buffer someone types into in turns,
like a prompt, can let go of its undo history with `buffer:clear_history()`,
so undo never reaches past the last turn. To tell someone how to set a
secret, `greed.secrets.variable("anthropic")` is the variable that does
(`ANTHROPIC_API_KEY`).

To show a file to the user, `core.file.open(path)` opens it in the main
view, as the picture for an image and the pages for a PDF, and
`core.file.open_at(path, line, col)` puts the cursor there too (0-based
line, byte column). A file Greed can't show goes to the program that opens
it, as the user's `core.file.open_with` says; `core.file.opening(path, mime)`
says beforehand how one would open ("viewer", "text", "outside", "binary"
or "refused") and in words, as mail does under each attachment, and
`core.file.open_outside(path)` hands one out (never a program).
`core.file.open_link(uri)` opens a web address with the `link-opener`
option or the system's opener, and `core.file.open_page(path)` a page a
plugin wrote in the browser. A plugin that shows some kind
of file its own way registers an opener; it goes when the plugin does:

```luau
core.file.opener(function(path)
	return string.match(path, "%.csv$") ~= nil
end, function(path, views)
	local table_buffer = greed.create_buffer("csv", render(path), { readonly = true })
	for _, view in views do
		view:show(table_buffer)
	end
	return nil -- or why it can't, and the file opens as text
end)
```

Files opened another way, like `greed FILE` from a shell or `greed.open`,
open as text first and the opener then takes over the views showing them.

Links of a scheme of your own, like `ticket:PROJ-12` in a note, open in
Greed once a plugin says how; `open_link` then calls it, wherever the link
was:

```luau
core.file.link_scheme("ticket", function(uri)
	show_ticket(string.sub(uri, #"ticket:" + 1))
end)
```

For files on disk with no buffer, `greed.fs` has the usual operations, so
a plugin needs no `rm` or `mv`. Each returns `true`, or nil and why. Paths
starting with `~` are in your home folder, as in a shell:

```luau
greed.fs.write(path, text)                        -- creates its folders too
greed.fs.write(path, text, { private = true })    -- readable only by you (0600)
greed.fs.write(path, text, { background = true }) -- on another thread; waits like greed.sleep
greed.fs.mkdir(dir)                               -- and the folders above it
greed.fs.copy(from, to)
greed.fs.rename(from, to)
greed.fs.remove(path)                             -- a file, link or empty folder
greed.fs.remove(dir, { recursive = true })        -- a folder and all in it
greed.hash.sha256(text)                           -- hex, to tell if text changed
greed.hash.sha256_file(path)                      -- to check a download
greed.hash.random(32)                             -- 32 random bytes as hex, for a one-time code
```

Something already gone counts as removed. `remove` and `rename` raise an
error rather than touch the root folder, your home folder, a path with `..`
in it or a folder holding Greed's own approvals or secrets, so a path built
wrong can't take more than it should. `greed.fs.stat(path)` says what's
there: its `kind`, `size`, `mode` and when it was `modified` (seconds
since 1970). `greed.hostname()` is the machine's name, and
`greed.fs.dirs()` gives the folders Greed uses: `home`, `config`, `cache`,
`data`, `temp` (the system's folder for temporary files) and, at the far
end of `greed ssh`, `brought`, the copy of your config it brought.

### History

Every edit is recorded with who made it and why. `buffer:history()` lists
the transactions, newest first, each with its `author` (`"user"`,
`"plugin"`, `"agent"` or `"external"`), `cause` (the command it was made
for), `time`, `group` and `changes`. Filter by any of those, or with
`since` and `limit`:

```luau
-- What did the user just change?
for _, tx in buffer:history({ author = "user", limit = 5 }) do
	print(tx.cause, tx.changes[1].text)
	local before = buffer:text_before(tx.id) -- the text before it
end
```

A command's edits carry its name as their cause; `greed.history.set_cause`
names them otherwise. To make edits in several buffers undo as one step,
put them in a group:

```luau
local group = greed.history.new_group()
greed.history.set_group(group)
-- ... edit any buffers ...
greed.history.set_group(nil)
greed.history.undo_group(group) -- every buffer back, or nil and why not
```

Undoing a group refuses, and changes nothing, when something was done on
top of it in one of the buffers since.

Undo keeps every branch. `buffer:undo_tree()` gives every state the text
has been in, `{ nodes = { { id, parent, children, time } }, current }`,
where node 0 is the text as loaded and undo goes to a node's parent; and
`view:undo_to(id)` takes the text to any of them, on any branch, which is
what `alt-u` and the `undo-tree` plugin's viewer are built on.
`buffer:undo_save()` gives the tree as JSON and `buffer:undo_restore(json)`
takes it back for the text as it is now, only while nothing was done since
the buffer was loaded; that's how undo lasts across restarts.

A buffer whose edits nobody undoes, like a terminal's or a log a plugin
keeps adding to, can stop keeping them with `buffer:forget_history()`, so
it doesn't grow without end.

When a plugin writes into a buffer someone also types in, like output
streaming in above a prompt, `buffer:edit(f, { undo = false })` keeps its
edit out of undo: undo skips it and still takes back only what was typed,
moved to wherever the plugin's text put it. Redo can't go down other
branches after such an edit, and typing the plugin's edit replaced or
deleted is no longer there to undo.

```luau
buffer:edit(function(e)
	e:insert(output_end, line .. "\n")
end, { undo = false })
```

The `operations` plugin builds on groups: it names the work, remembers the
files it changed and the programs it ran, and gives it a review and an
undo key.

```luau
local operations = require("@operations")
operations.run("rename parse to parse_line", function(op)
	-- edit any buffers, then
	operations.exec(op, { "cargo", "test" })
end)
```

### Syntax trees

Buffers in a language with a tree-sitter grammar have a syntax tree.
`buffer:node_at(pos)` is the smallest named node there, and nodes know
their `kind`, `from`, `to` and `field`, and can go to their `parent()`,
`children()`, `child("body")`, `next()` and `prev()`.
`buffer:query(source)` runs a tree-sitter query and returns each match as
a table from capture name to node:

```luau
-- Select the name of every function in the file
local ranges = {}
for _, m in buffer:query("(function_item name: (identifier) @name)") do
	table.insert(ranges, { anchor = m.name.from, head = m.name.to })
end
view:set_selection({ ranges = ranges, primary = 1 })
```

`tostring(node)` shows the node's subtree, which helps when writing a
query. A node describes the text as it was when you got it; after an
edit, find it again. Right after an edit that would take a while to parse
(a big file, or code tree-sitter has to recover from), the tree is the one
before with the edit applied, its nodes moved along with the text, until
the new one comes a moment later.

Each language's queries are in `greed.syntax`: `greed.syntax.query("rust",
"textobjects")` is the one in use, and `greed.syntax.set_query` sets one.
A plugin can also ship them as files in its own `queries/LANGUAGE/` folder
(see [Configuration](using.md#highlighting-and-syntax-queries)), and the
`plugin.loaded` event says when a plugin with some arrives.

Folding uses a language's `folds` query, or indentation without one. To
fold a language another way, give core a provider that returns the first
and last line of the block around a line:
`require("@core").folds.provider("org", function(buffer, line) ... end)`.
Markdown folds sections this way. New lines' indent works the same way,
with the `indents` query and `require("@core").indent.provider`, whose
functions get the buffer and the place a line break goes in and return the
new line's indent.

The editor can have several projects open. `greed.project.current()` is
the one shown, with its `root`; `greed.project.open`, `switch` and `close`
manage them, and `buffer:project()` says which one a buffer belongs to.
Panels belong to the project they were opened in, so a plugin that keeps
one (like a results panel) should keep one per project.

Each project has tabs (`greed.tab.list`, `new`, `switch`, `close`,
`rename`), and each tab has panes laid out side by side and one above
another. `view:split("right", buffer)` opens a pane, `view:neighbor("left")`
finds the one beside it, `view:resize("down", 2)` moves its edge, and
`view:close()` closes it. `greed.view()` is the focused view, `greed.view(id)`
the view with that id (nil once it's closed), and the shown tab's active
pane is where `greed.open` opens files. Tab ids work whichever project the
tab is in: `greed.tab.switch` and `view:focus()` on a tab or view of
another project show that project.

`greed.tab.layout()` gives a tab's arrangement as a tree, and
`greed.tab.set_layout(tree)` arranges its panes another way:

```luau
local a, b, c = table.unpack(greed.tab.current().panes)
-- a across the top, a quarter high; b and c side by side under it
greed.tab.set_layout({
	split = "column",
	sizes = { 1, 3 },
	children = { a, { split = "row", children = { b, c } } },
})
```

## Showing things

- Decorations style text without changing it, and move with edits:
  `buffer:decorate("my-plugin", { { from = 0, to = 5, style = "diagnostic.error" } })`.
  A mark can style whole lines, add virtual text inside or after a line,
  put a sign in the gutter, or draw text over the buffer's (like jump
  labels). Other things a mark can do:

  - `conceal` hides text (like a link's brackets), shown again as `reveal`
    says: `"line"` (the default) when a cursor is on its line, `"cursor"`
    when one is inside it, `"never"`, `"auto"`, which follows the mode: on
    the cursor's line while typing, otherwise once the cursor is inside it
    past its start (as the `markup-reveal` option says), or `"typing"`, as
    `"auto"` while typing and never otherwise, as for a table's borders.
    Markdown and notes use `"auto"`, so their marks stay as they are when
    the mode changes (`greed.reveal(how, typing)` is what core calls as it
    does).
  - `plain = true` draws a mark's text without syntax highlighting, as for
    a tool's output in a Markdown buffer.
  - `fold` folds lines away under the first one; with `peek` they show
    while a cursor is on that first line too.
  - `nowrap` keeps the lines it touches from wrapping, cut at the edge with
    the view scrolling sideways to the cursor (`view:side_scroll()`).
  - `lines` shows lines that aren't in the buffer under its own, whole or
    in pieces with styles of their own.
  - `action` (a command name) makes a mark's text a button: clicking it, or
    `enter` on it in normal mode, puts the cursor at the mark and runs the
    command.
  - `scale = 2` (up to 4) makes its text bigger, like a heading: each
    character takes twice the cells across and its row two rows down. The
    window draws it big, and so does kitty; other terminals show it at the
    normal size.
  - `gutter` styles the line numbers of the lines a mark touches.
  - `data` keeps anything you like with a mark (plain tables, strings,
    numbers), given back by `buffer:decorations(ns)`.

  `buffer:decorate(ns, marks, { from = a, to = b })` replaces only the
  marks starting from `a` up to `b`, for plugins that draw again only the
  lines an edit changed. `buffer:marks_at(pos)` gives the marks over a
  place in every namespace.
  `view:decorate(ns, marks)` is the same for marks one view draws and the
  others don't, like blame for the line the cursor is on in one pane of a
  file that's open in two. It replaces only that view's marks in `ns`, and
  they go when the view closes. Every client sees them in that pane.
  Language servers' diagnostics are marks too, in the `"diagnostics"`
  namespace, which is how they follow edits.
- Multibuffers show excerpts of many files in one buffer, edited in place:
  `require("@multibuffer").open({ { path = path, from = 9, to = 12 } },
  { summary = "3 places" })` gives a buffer to show in a panel or float,
  or in the shared results panel with `.show(buffer, "Title")`. An excerpt
  can carry `marks` to style ranges in it and a `note` shown after its
  file's name. Edits in it change the files as you type, and changes to
  the files show in it. Search results, references and the problems list
  use one.
- Images: `greed.image.load(path)` reads a PNG, JPEG or GIF and gives an id,
  and a mark with `image = { id = id, cols = 20, rows = 8 }` draws it over
  that many cells from its start. `greed.image.cells(id)` says how many
  cells it covers at its own size, and `greed.image.cell_size()` how many
  pixels a cell is.
- PDFs: `local doc = greed.pdf.open(path)` reads one, `doc.pages` counts
  its pages, `doc:render(page, scale)` draws one as an image id at `scale`
  pixels per point, and `doc:text(page)` gives its text, line by line. All
  three wait, like `greed.sleep`.
- A view can show part of its buffer: `view:narrow(from, to)` shows only
  those lines (no arguments shows all again), and `view:set_filter(text)`
  keeps only the lines with every word of `text`, as `/` in a shell block
  does, fields like `level>=warn` and `.a.b` sections included; the other
  lines stay in the buffer.
- Floats show a buffer over the main view, and panels beside it:
  `greed.float(buffer, { title = "Info", width = "60%" })`,
  `greed.panel(buffer, { side = "right", width = 40 })`. For text to read,
  `core.floats.show_text(title, text, { kind = "my-info" })` opens a
  read-only float that `esc` or `q` closes, replacing the one before of
  that kind; `anchor = "cursor"` with a `width` and `height` opens it
  small by the cursor, like a hover. For a float to type in, like your own prompt,
  `core.floats.typing(buffer, spec, { on_change = ..., on_close = ... })`
  switches to the editing style's typing mode (insert, in Helix's and
  Vim's) and puts the mode and focus back however the
  float closes, whether by its `close()` or by closing its view; it's what
  the prompt, pickers, the command line and the completion menu use.
  A float's spec can also put text on its border (`label` at the right of
  the top, `footer` in the middle of the bottom, plain or in styled
  pieces), leave the border off (`border = false`, for a one-line strip),
  or hide it (`hidden = true`: its view and buffer stay, and focusing it
  shows it again; `greed.floats({ hidden = true })` lists hidden ones too).
  Sizes and places (`x`, `y`) are cells, or shares of the screen like
  `"37.5%"`, which keep a float in proportion on every attached client's
  screen; `core.floats.in_shares(box)` turns a box in cells into those.
  `anchor` puts it in a corner or at an edge (`"top-left"`, `"right"`,
  ...) when `x` or `y` is left out. With several clients attached, a float
  is shown only to the client it opened for, like a picker or a prompt,
  unless it's `shared = true` (meant for everyone, like a review) or
  belongs to a tab (`tab = true`). Keep what a float you open belongs to
  apart for each client too, by `greed.client.id()`.
  To show something in a float of the tab, laid out by its
  [float layout](using.md#float-layouts), use
  `require("@panes").floats.show(buffer)`, and say something needs the
  user with `core.attention.set(key, { label, reason, buffer })`, where
  `key` is the thing's object id (`terminal:12`) and `buffer` where to
  look; its float gets a dot, and `core.attention.list()` gives everything
  waiting, oldest first. With `tell = true` the hub tells the user of it
  wherever they are, as it does an agent waiting (a chat message for them,
  say). `core.attention.set(key, nil)` takes it off.
- Pickers (`require("@picker").pick(title, items, choose, options)`)
  filter a list as you type, with an optional preview, or ask a function
  for items as the query changes. `on_move` hears each item as it becomes
  the current one and `on_cancel` hears `esc`, for trying things out live.
  With `paths = { dirs = true, choose = function(path) ... end }`, typing a
  path lists the folder's contents, and `tab` completes one into the query.
  `tags = function(item, word) ... end` makes words like `@shell` in the
  query keep the items it says have them, as `space space` does with kinds.
  `keys = { ["ctrl-e"] = function(items, current) ... end }` adds keys of
  the picker's own, and `fallback(query)` runs on `enter` when nothing
  matches. `require("@picker").add_places(name, function() ... end)` adds
  places of your own to `space space`, each `{ kind = "session", label =
  "notes on eris", tags = { "eris" }, go = function() ... end }`, after the
  buffers; `@kind` and `@tag` keep them and `enter` runs `go`. With
  `actions = { { name = "stop", run = function() ... end } }`, `ctrl-a`
  offers them.
- An action that decides for the user, like answering an agent's question,
  is `yours = true` in `core.actions.action`: an agent asking for it
  through `act` is refused.
- The completion menu asks sources before the language server, in any
  buffer, a file or not: `require("@lsp").completion.source(function(view,
  ask) ... end)` returns items like `{ label = "src/", text = "src/", from
  = 12 }` (`from` is where the text it replaces starts; the word before the
  cursor by default), or nil to leave it to the next source. `detail`
  shows dimmed after the label, and `badge` goes between the two, a word
  saying whose it is (the shell's own things say `greed`). `ask.explicit` is true when
  you asked with `tab` or `ctrl-space` rather than by a pause in typing. A
  source can wait, for a program say; its answer is dropped if more was
  typed meanwhile. A second argument says how its menu behaves:
  `{ enter = "selected" }` has `enter` take only an item moved to while
  `completion-enter` is `auto` (`"first"`, the default, takes the first);
  `tab = "insert"` makes `tab` complete in place as a shell does (the only
  match or what all matches start with at once, then each item in turn);
  and `arrows = "after-tab"` leaves `up` and `down` to the buffer while a
  menu that opened by itself hasn't been moved into. The shell completes
  its prompt this way, with all three. With `adds = true` a source doesn't
  decide alone: what it offers goes after the language server's items, as
  the words from open files do. With `first = true` it's asked before the
  sources already there, as Hoard's `/` menu is, ahead of completing
  paths. A plugin that binds `tab`, `enter` or the arrows for typing in
  its own kind of buffer calls `completion.keys_over(kind)` so the menu
  keeps those keys while it's open.
- The theme maps style names to looks, as in
  `greed.theme.set({ ["my-plugin.match"] = { fg = "yellow" } })`. Use your own
  names so users can restyle them. Themes themselves go under those
  entries: `greed.theme.base(entries)` replaces the whole base, which is how
  the theme plugin switches themes.
- The status line is pieces you can add to or take away from with
  `require("@statusline").add` and `.remove`, or replace with `greed.statusline`.
  A piece returning `{ text = "3 due", action = "notes-agenda" }` runs the
  command when clicked, and `style = "ui.statusline.warning"` draws it as a
  warning. A piece that takes time to work out, like a repository's state,
  goes in with `add_async(side, name, { refresh, every, on })`: `refresh`
  runs in the background (every `every` ms, and on the events in `on`) and
  the status line shows what it last returned, never waiting for it. A
  plain piece that takes over 10 ms to draw is moved to the background the
  same way.
- `greed.client.notify(title, body)` sends a notification to your desktop
  through the client you used last: the terminal shows it (OSC 9, or OSC
  777 in foot and urxvt) with a bell while it isn't focused.
- Features are what a plugin turns on for some buffers beyond their
  language, like notes for Markdown in the notes folder. Name yours with
  `require("@core").features.add("todos", function(buffer) return ... end)`,
  and the status line shows it after the language (`markdown · todos`).
  `core.features.of(buffer)` lists the ones on.
- Choices in Markdown (`- ( )`, `- (x)`) are read with
  `require("@markdown").choices.list(buffer)`: each group with its question
  (the line above it) and its options, `picked` or not.
  `choices.on_pick(fn)` hears each pick, after the text has changed. A pick
  only edits text; what it does is up to the plugin listening.
- `require("@markdown").document(buffer)` shows a Markdown buffer the way
  the reading view does, for good: read-only, no markup, code in its
  language's colors and links to follow. Hover info uses it, like this:

  ```luau
  local view = core.floats.show_text("Hover", text, { language = "markdown" })
  require("@markdown").document(view:buffer())
  ```
- `require("@markdown").structure(buffer)` reads a Markdown buffer once
  per edit and gives its `headings` (level, text, lines), `code` blocks
  (info string, fences' lines, the code's bytes), list `items` (bullet,
  todo box, lines), `tables` and `links`, with `heading_at`, `code_at`,
  `item_at` and `table_at` by line, and the lines' text. It uses the
  syntax tree, so a `# comment` in a code block isn't a heading. Give it a
  file's text instead of a buffer to read that.
  `markdown.conceal({ ns, wants, draw })` draws marks over the Markdown
  buffers `wants` says, calling `draw(buffer, structure, first, last)`,
  which returns the marks, for the lines an edit changed (and any code block or table they touch)
  rather than the whole file. It returns a function that draws a buffer,
  or all of them, again in full. `markdown.drawn(buffer)` says whether a
  buffer shows as a document, for `wants`. `markdown.values.scope(buffer)`
  is what its formulas can name (fields, `let`s, tables, answers), to work
  out a `core.formula` there. `markdown.values.provide({ names, value })`
  adds names a buffer's text doesn't hold, like the data plugin's tables.
- `require("@core").ui` draws an interface as a buffer's text and marks, so
  search, copy and an agent's `read` work on it as on any text, the same in
  the terminal and the window. A view is a function from its state to
  widgets; `ui.mount(buffer, render, state)` draws it for the width of the
  buffer's views, and `view:set(patch)` merges into the state and draws
  again, changing only the lines that changed ([Building
  interfaces](ui.md) is a guide, with a worked example):

  ```lua
  local ui = require("@core").ui
  local view
  view = ui.mount(buffer, function(state)
      return ui.column({
          ui.field("search", state.query, function(text) view:set({ query = text }) end),
          ui.table({ columns = { "name", "total" }, rows = state.rows, on_open = show }),
          ui.row({ ui.button("Refresh", refresh), ui.toggle("Live", state.live, set_live) }),
      })
  end, { query = "", rows = {}, live = false })
  ```

  `text`, `line` (of `ui.span`s), `column`, `row`, `box`, `gap`, `button`,
  `field` (asks with a prompt), `toggle`, `list`, `grid` (columns lined up
  without borders, as the agent sessions list is) and `table` are there. A
  widget is pressed with `enter`, `space` or a click, and `tab` and
  `shift-tab` go between them; the cursor is the focus, so each client has
  its own. A span's `value` is what its line stands for, found with
  `view:value_at(pos)` (a list's item, a grid's row); on a line of several
  things, like a strip of tabs, `value_at` gives the value of the span at
  `pos`;
  `ui.list(items, spans, { open = f, current = n })` opens an item when
  pressed and marks row `n` as a menu's selected one, for a list whose
  cursor is elsewhere, like a picker's under its query. With
  `ui.mount(..., { key = function(value) return value.id end })` each
  cursor stays on its item as the lines change places. A span's `tag` is
  found with `view:spots(tag)`, and its `line` styles its whole line.

  For a long view that changes at one end, like a chat streaming in, wrap
  each part in `ui.keyed(key, version, build)`: a part whose version is
  the same as last time isn't laid out or drawn again, so a token costs
  what its message does. `view:soon(patch)` draws once for a burst of
  changes:

  ```lua
  ui.column(map(messages, function(m)
      return ui.keyed(m.id, #m.text, function() return ui.text(m.text) end)
  end))
  ```

  A keyed part is laid out again for a new width too, unless
  `ui.keyed(key, version, build, { any_width = true })` says its lines
  don't depend on it (the view wraps them, as it does a message's text).
  While a view goes on resizing, as when its edge is dragged, it's drawn
  at once, then at most every 100 ms, then for where it ends.

  With `ui.mount(..., { input = true })` the view is drawn at the top of
  the buffer and what's written under it is yours, like a chat's box:
  `view:input()` reads it, and the view is read-only above it. A span's
  `marks` are drawn with it, counted from its start; `view:each(f)` goes
  through the lines with values; `ns` and `width` choose the namespace of
  its marks and how wide it's laid out. `view:line_of(f)` finds the first
  line whose value `f` takes, `view:value_on(line)` gives a line's value,
  and `ui.matched(text, positions)` picks out what a fuzzy search matched,
  as menus show it. With `draw = false` a view is drawn first at its first
  `redraw`, so it can be mounted while what it draws from is being made.

  `ui.pieces(node.lay(width))` gives a node as a mark's `lines`, as the
  data plugin draws its tables under a block.
- `require("@core").data` is where tables of data come from: one shape,
  `{ columns = { { name, kind? } }, rows = { { [name] = value } } }`, and
  sources by name. `data.source({ name, doc, runs?, read, watch?, actions? })`
  adds one: `read(ask)` gives the table for an ask (`args`, `body`,
  `values` to bind as parameters, `dir`, `limit`, `offset`), and may wait.
  A source that `runs` a program or reaches a service is let run per file
  as code blocks are. `actions`, each `{ name, run(row), close? }`, are
  offered as buttons under a row when it's opened from the table; a row
  can carry values besides its columns for them to use. `data.read(name,
  ask)` reads one, and a Markdown block named after a source shows its
  table (the data plugin).

## Clients

Several terminals or windows can show one session at once, like your
desktop and a laptop over `greed ssh`. Each is a client, with its own
cursors, focus, mode, half-typed keys and macro recording; buffers and
their undo history are shared. Code always acts for one client: a command
for the client whose key, click or menu ran it, an event handler for the
client the event is about, and what either starts (`greed.spawn`, a timer)
for the same client. `greed.view()`, `greed.mode.get()`, `greed.next_key()`
and selections all belong to that client.

```luau
greed.command({
	name = "who",
	run = function(ctx)
		local me = greed.client.current()
		greed.echo(`{me.name} ({me.kind}), one of {#greed.client.list()}`)
	end,
})
```

`greed.client.current()` and `greed.client.list()` describe clients:
`id`, `name` (like `tui@laptop`), `kind`, `remote`, `size`, `layout`,
`color` (the color its cursors show in for the others) and `person`.
`ctx.client` is the id of the client a command runs for, and events about
a client carry it as `event.client`.

Other sessions can be asked how they're doing, as `greed ls` does:
`greed.session.status(name)` gives what the session `name` on this machine
says of itself (`session`, `attention`, `agents`), and
`greed.client.home(client)` what the hub on the machine a client attached
from says, for a session over `greed ssh` to show what waits back home.
Both ask as an ordinary client, so nothing there can be done through
them, and both wait, so call them from a command, a handler or
`greed.spawn`.

## Waiting

Commands and event handlers can wait without freezing the editor, and
waiting always looks the same: the call returns once the answer is there.

```luau
greed.command({
	name = "rename-file",
	run = function(ctx)
		local name = core.prompt.ask("New name", ctx.buffer:path())
		if name == nil then
			return -- cancelled
		end
		local moved = greed.process.run({ "git", "mv", ctx.buffer:path(), name })
		if moved == nil or moved.code ~= 0 then
			greed.echo(moved and moved.stderr or "git isn't installed")
			return
		end
		local choice = picker.choose("Open it?", { { label = "yes" }, { label = "no" } })
		if choice and choice.label == "yes" then
			greed.open(name)
		end
	end,
})
```

These wait like this:

- `greed.sleep(ms)`, `greed.next_key()`, `greed.process.run(...)`,
  `greed.http.request(...)`, `greed.lsp.request(...)`, `greed.fs.grep(...)`
  and `greed.plugin.check(...)`
- `picker.choose(title, items)` and `core.prompt.ask(title)`, which give
  nil when you close them

`picker.pick` and `core.prompt.open` take callbacks instead, for pickers
that stay open while you work. `core.prompt.open` returns the prompt's
view, to put a label on its border, and its `kind` option gives the prompt
keys of its own, the way the vscode style's find bar binds `enter` to the
next match.

`greed.signal()` lets one piece of code wait for a value another sends,
one waiter each. `core.joined(f)` makes `f(key)` run once for calls that
come at the same time with the same key: the others wait and get what it
gave, so a program several ask for at once starts once.
`greed.animate(ms, step)` calls `step(t)` once a frame; the flash on copy
is built on it. `greed.fs.watch(path)` makes a "file.changed" event come
whenever that file changes, from anywhere; it's how your config reloads.

A search the user types should mind case as they set it:
`core.search.pattern(regex)` gives the regex to search with, as
`search-case` says, and `greed.fuzzy(query, items, { case =
core.search.case() })` the same for fuzzy matching. A kind of search with
a better default of its own gets an option for it, `KIND-search-case`,
from `core.search.kind(name, default, what)`, as notes do with
`core.search.kind("notes", "ignore", "searching notes")`; then pass the
kind, `core.search.pattern(query, "notes")`.

`greed.run(name)` starts a command and returns as soon as that command
waits for something, so the code after it doesn't see what the command
did after a key or a reply. `greed.run(name, { wait = true })` waits until
the command has finished, the same way as the calls above.

Waiting only works where code runs as a coroutine: commands, event
handlers, and `greed.spawn(f, ...)`, which runs `f` that way and returns at
once, for work in the background. Called anywhere else, like a status line
piece or a plugin's top level, the calls that wait raise an error instead of
running on the editor's thread, so no plugin can freeze the editor on a
slow program or server.

Heavy work doesn't freeze it either. A command or handler that works for
more than 15 ms without waiting is paused, the editor handles keys and
draws, and it carries on where it was, so a slow plugin is only slow
itself. On Linux only time spent working counts toward the 15 ms, so a
busy machine doesn't change where code is paused. `coroutine.yield()`
with nothing pauses the same way on purpose. Your own coroutines, like a
generator made with `coroutine.wrap`, are never paused this way.

A pause shows what's half done, like a buffer's new text with its old
decorations; `core.atomic(f, ...)` runs `f` to its end with no frame drawn
in between, so do the long work before it and only the changes that
belong together inside it, which can't wait. A command or handler that
works for a whole minute without finishing is stopped and Greed says so.

Code that can't be paused, like a status line piece or a plugin's top
level, is timed instead: anything that holds the editor up for 50 ms or
more is kept with its plugin and what it was doing, `:stalls` lists them,
and over 250 ms Greed tells you right away. To see where time goes when
nothing stalls, `:profile` (or `greed.profile.start()` and `stop()`)
counts every run of plugin code and the editor's own work by plugin and
what it did, the most time first.

Every plugin's top level runs each time Greed starts, so keep it to
registering: commands, keys, options, handlers. Read files, scan folders
or start programs the first time they're needed, or from a handler,
like this:

```luau
local index = nil
local function notes()
	index = index or build_index() -- the first time a command needs it
	return index
end
```

That way adding plugins hardly slows starting, and nobody has to set up
lazy loading in their config. `:plugins` says how long each one took to
load when it's a millisecond or more; `greed.profile.loading()` gives
the numbers.

To see what your plugin does as it runs, `greed.debug.log(...)` keeps a
line while the `plugins` debug topic is on, or `plugin:NAME` for yours
alone (`:debug plugin:myplugin`); off, it returns at once, and
`greed.debug.on()` says whether it's on, for lines that cost something to
make. `:debug-log` shows them with the editor's own topics (`keys`, `runs`
and the rest, in [Debugging](using.md#debugging)), and
`greed.debug.lines({ after = id })` returns them.

Keys typed while a key's command is still at work wait their turn, so
typing ahead gives the same result as typing slowly. At work means paused
as above, or waiting on a timer, a program, a request or a command that
is. A command waiting for you (`greed.next_key()`, a prompt, a picker, any
`greed.signal()`) isn't at work, and gets the next keys as they come.
Keys wait half a second at most, then run anyway. `esc` and `ctrl-c` get
through to a command at work at once, so they can cancel it, but behind
keys already waiting they keep their place. Pastes and clicks wait in
line with the keys.

An error your command, handler or task doesn't catch shows on the status
line with your plugin and what it was running ("myplugin (on
buffer.opened): ..."). The last 100 are kept with where in your code they
happened: `:errors` lists them, `greed.errors()` returns them, and a
session also writes them to its log. A message of several lines, from
`greed.echo` or an error, shows its first line on the status line;
`:messages` shows recent ones whole, and `greed.messages()` returns them.

Whatever you pass the API, it answers with a value or an error: a position
past the end, a closed buffer or a size no screen has is an error you can
`pcall`, or is kept in range where the function says so. Should your code
run into a bug in Greed itself, that becomes an error too, starting
"internal error, a bug in Greed", kept like the others while the editor
carries on. Please report those.

Language servers ask things too: `greed.lsp.on_request(method, handler)`
answers a server's request, e.g. `workspace/applyEdit`, with what the
handler returns, and the handler can wait, e.g. on a picker, before it
answers. `greed.lsp.on_notification(method, handler)` hears what servers
tell the editor without asking, like `$/progress`; the handler gets the
parameters, the server's language and its root. The status line's language
server piece is built on it.

A server runs per language and project root. `greed.lsp.root(buffer)` is the
folder the buffer's server runs in, and `greed.lsp.running()` lists the
servers running, each with its language, root, command, whether it's ready,
and the last lines it wrote to stderr. A request whose server stops before
answering returns nil and an error saying so.

`greed.lsp.request(buffer, method, params)` asks the buffer's server
anything and waits for the answer. `greed.lsp.uri(buffer)`,
`greed.lsp.position(buffer, pos)` and `greed.lsp.offset(buffer,
position)` turn files and byte offsets into what servers count in and
back, and `greed.lsp.capabilities(buffer)` is what the server said it
can do.

## Events

A plugin reacts to what happens in the editor with `greed.on(event,
handler)`. The handler gets one table describing what happened. Format on
save, auto-save and the status line use it.

```luau
local greed = require("@greed")

-- Trim spaces at the ends of lines whenever a file is saved.
greed.on("buffer.saved", function(event: greed.BufferChanged)
	local buffer = event.buffer
	local trimmed = string.gsub(buffer:text(), "[ \t]+\n", "\n")
	if trimmed ~= buffer:text() then
		buffer:edit(function(e)
			e:replace(0, buffer:len(), trimmed)
		end)
		buffer:save()
	end
end)
```

| Event | When | What the handler gets |
|---|---|---|
| `buffer.changed` | After every edit to a buffer: yours, a plugin's, an agent's, or the file changing on disk | `buffer`, and `from_line` and `to_line`: the lines that changed since the last one, as they are now. `buffer:version()` grows with each edit, for caches |
| `buffer.opened` | A buffer was opened | `buffer` |
| `buffer.saved` | A buffer was written to its file | `buffer` |
| `buffer.closed` | A buffer was closed | `id`, the closed buffer's |
| `file.changed` | A file watched with `greed.fs.watch(path)` was written, created or removed, by anything | `path` |
| `mode.changed` | A client's mode changed | `from`, `to` |
| `command.run` | A command is about to run | `name`, the `keys` that ran it, `count` |
| `selection.changed` | A view's selection changed for a client, or it shows another buffer, by anything: keys, the mouse, undo, a plugin or an agent. Once a frame per view, before it's drawn, however many changes there were | `view` |
| `view.focused` | Another view has a client's focus: a pane, a float or a panel. Once a frame, before it's drawn | `view`, `from`, the view that had it (nil if it was closed), and `moved`, true when it moved under the client: another client showed another tab or closed what it had focused, or it followed again |
| `keys.pending` | A key sequence is under way, e.g. after `space`; `""` once it's done | `keys` |
| `option.changed` | An option was set | `name`, `value`, and `client` when it was set for one client alone |
| `lsp.diagnostics` | A language server reported problems for a buffer | `buffer`; read them with `greed.lsp.diagnostics(buffer)` |
| `message` | The status line is about to show a message: an echo, an error, a command that refused. What the handler echoes shows instead, and isn't told again, so echoing in it can't go on forever | `text`, and `error` when something failed |
| `view.resized` | A view has room, for a client, for a different number of rows or columns | `view`, `rows`, `cols` |
| `view.scrolled` | A view starts, for a client, at a different line; what the handler changes shows in the same frame, so one view can scroll another along | `view`, `line` |
| `view.closed` | A view was closed, e.g. a plugin's panel | `view`, the closed view's id |
| `pane.opened` | A split opened, from whichever plugin made it | `view`, and `from`, the pane beside it |
| `mouse` | The mouse pressed, released, dragged, moved or scrolled | `kind`, `button` or `dir`, the screen `col` and `row`, the keys held, and what's under it: `view`, `pos` in the buffer, a mark's or status line piece's `action`, a floating view's `border`, the `edge` between panes, or a `tab` |
| `terminal.output` | A terminal's program printed something | `terminal`; read it with `terminal:screen()` |
| `terminal.exited` | A terminal's program ended | `terminal`, `code`, `signaled` (a signal ended it) |
| `client.attached` | A client attached to the session, e.g. `greed FILE` | `client`, the `path` it asked to open, whether it wants a `terminal` or the project's `shell` (`greed --shell`), whether it came over `greed ssh` (`remote`) |
| `client.detached` | A terminal or window went; the session goes on without it | `client` |
| `client.paste` | Text was pasted from the system clipboard | `text` |
| `control.request` | A request came on the session socket (`greed ctl`, agents) | `id`, `method`, `params`, `client`, `connection`; answer with `greed.control.reply` |
| `control.closed` | A session socket connection closed, after its last request came; requests from it still waiting have nobody to answer | `connection` |
| `ssh_agent.use` | A program in a session from `greed ssh` asks to sign with your ssh key, through the client relaying your agent; handlers run as that client. The core plugin asks you, as `ssh-agent-confirm` says. With no answer, or no handler, it's refused | `id`, `client`, `host` (the client's machine); answer with `greed.ssh_agent.answer(id, allowed)` |
| `plugin.loaded` | A plugin was loaded or reloaded | `name`, `dir` |
| `plugin.unloaded` | A plugin was unloaded | `name` |
| `editor.started` | Once, when the editor is up with every plugin and your config loaded | nothing |
| `editor.quitting` | Just before the editor quits | nothing |

`space h e` (`:describe-event`) shows any event's fields, the types that
come with `require("@greed")` have them all, and the reference has them
too, with their types: [Events](reference/events.md). Give the handler's
parameter its type, as above (`greed.BufferChanged`), so the type checker
catches a misspelled field. A name that isn't on this list, like
`"buffer.chnaged"`, is an error, from the type checker and when the code
runs.

A handler stays until its plugin unloads or `greed.off(event, handler)`
removes it, given the same function. Removing one that's gone does nothing,
and a plugin can only remove its own. That lets something listen only while
it's open:

```luau
local function show_notes(buffer: greed.Buffer)
	local view = greed.float(buffer, { title = "Notes" })
	local function saved(event: greed.BufferChanged)
		if not view:valid() then
			greed.off("buffer.saved", saved)
		elseif event.buffer == buffer then
			greed.echo("notes saved")
		end
	end
	greed.on("buffer.saved", saved)
end
```

Who made an edit is in the buffer's history: `buffer:history({ limit = 1
})[1].author` is `"user"`, `"plugin"`, `"agent"` or `"external"` (the disk),
so a handler can skip the edits it doesn't care about, or its own.

A plugin with buffers of its own kind can take their mouse events first
with `require("@core").mouse.claim(kind, handler)`.

### Writing handlers that stay fast

Each handler runs in a coroutine of its own as soon as the event happens,
so it can wait like a command (see [Waiting](#waiting)) and a slow one is
paused after 15 ms instead of holding up the editor. Still, some events
come often: `buffer.changed` on every key you type in insert mode,
`mouse` on every move, `view.scrolled` on every line scrolled. Handlers
for those should do little each time, and leave heavy work until things
are quiet.

The usual way is to count, wait, and only act if nothing came since. This
is how auto-save works:

```luau
local edits = {}

greed.on("buffer.changed", function(event)
	local id = event.buffer:id()
	local this = (edits[id] or 0) + 1
	edits[id] = this
	greed.sleep(1000)
	if edits[id] == this then
		-- A second without edits: do the heavy work now.
	end
end)
```

A handler that edits the buffer that changed makes another
`buffer.changed`, so check whether there's anything to do first, as the
trimming example does, or it goes round forever.

## Options

`greed.option.define({ name, doc, default })` adds an option users set
with `:set name value` or `greed.option.set(name, value)` in their config.
The default fixes its type, a boolean, a number or a string, and setting it
to anything else is refused, as is a name no plugin defined (the error
names options with names like it). `greed.option.get(name)` reads it, and
`option.changed` says when it changes. When a plugin is reloaded, an option
it defines again with the same type keeps the value it was set to.
`greed.option.set(name, value, { client = true })` sets a value for the
client you're at alone, like a window's font size; `get` gives that
client its own value when it has one.

```luau
greed.option.define({
	name = "trim-on-save",
	default = true,
	doc = "Trim spaces at the ends of lines when saving",
})

greed.on("buffer.saved", function(event: greed.BufferChanged)
	if greed.option.get("trim-on-save") then
		-- ...
	end
end)
```

An option that takes one of a few values lists them as `choices`. Setting
it to anything else fails with an error naming them, `:set` offers them as
you type, and `:describe-option` shows them:

```luau
greed.option.define({
	name = "trim-style",
	default = "trailing",
	choices = { "trailing", "all", "off" },
	doc = "What trim-on-save takes away",
})
```

An option whose value gets run, like a command line, says which
capability setting it takes with `needs`. Then only code with that
capability can set it, besides you (`:set`, your config), so a plugin
without `proc` can't make yours run a program of its choosing. Greed's own
options like `link-opener` and `terminal-shell` need `proc`, and
`agent-eval` needs `eval`. An option belongs to the plugin that defined
it: another plugin can't define it again.

```luau
greed.option.define({
	name = "deploy-command",
	default = "make deploy",
	needs = "proc",
	doc = "What :deploy runs",
})
```

## Programs and terminals

`greed.process.run(command, opts)` runs a program to the end and returns
how it went: `code` (or the `signal` that ended it), `stdout` and
`stderr`. `opts` takes `stdin`, `cwd`, `env` (`false` leaves a variable
out), `timeout` in milliseconds (then `timed_out` says if it ran out),
`group` (a process group of its own, so the kill reaches what it started)
and `on_start(child)`, which gets the program as it starts, to stop it
from elsewhere:

```luau
local ran = greed.process.run({ "kubectl", "get", "pods", "-o", "json" }, { timeout = 5000 })
if ran and ran.code == 0 then
	greed.echo(#greed.json.decode(ran.stdout).items .. " pods")
end
```

Like a spawned program, it's your plugin's and goes with it.
`greed.which("kubectl")` says where a program is, or nil when it isn't
installed. `greed.terminal.spawn({ command, rows, cols })` starts one
in a terminal: `terminal.output` events say there's something new to read
with `terminal:screen()` and `terminal:scrollback(from)`, and
`terminal:key("ctrl-c")`, `terminal:write(text)` and `terminal:resize(rows,
cols)` talk back. `terminal:interrupt()` interrupts it as ctrl-c does,
and also reaches a program that has only just started, which a typed
ctrl-c can miss. Styles in a screen are inline names like `=fg:red bold`,
which you can use in your own marks too. A row says `wrapped` when its
line carries on on the next row, so long lines can be joined again.
`terminal:modes()` tells what kind of program runs: `alternate` (a full
screen program), `canonical` and `echo` (both off in raw mode, only `echo`
off while a password is read), `mouse`, `app_cursor` and
`bracketed_paste`. In `env`, a variable set to `false` is left out of what
the program inherits. A terminal ends with the plugin that started it.

`greed.process.spawn(command, { cwd, env })` starts a program to talk to
over its input and output, like an agent or a server speaking JSON-RPC.
`child:write(text)` sends it input, `child:read()` waits for the next
piece it prints (nil once it exited), `child:close()` closes its input,
and `child:wait()` waits for its exit code, or nil and the signal that
ended it (`nil, "INT"`). It ends with the plugin that started it, too.
A program that prints faster than you read waits once 8 MB is unread, as
on a full pipe. Drop every reference to a child and it runs on without
you, what it prints thrown away.

```luau
greed.spawn(function()
	local child = assert(greed.process.spawn({ "sh", "-c", "read x; echo got $x" }))
	child:write("hello\n")
	greed.echo(child:read()) -- got hello
end)
```

What it prints as errors is kept for `child:stderr()`. With `stderr =
"stream"` it arrives from `child:read()` as well, in the order it comes,
and `read` says where each piece came from. With `group = true` the
program starts a process group of its own, so `child:signal("INT")` and
`child:kill()` reach whatever it started too, as ctrl-c does in a shell.
As for terminals, `false` in `env` leaves a variable out.

```luau
greed.spawn(function()
	local child = assert(greed.process.spawn({ "make" }, { stderr = "stream", group = true }))
	while true do
		local piece, from = child:read()
		if piece == nil then
			break
		end
		greed.echo(`{from}: {piece}`)
	end
	print(child:wait()) -- 0, or nil and "INT" after child:signal("INT")
end)
```

To show a terminal you started yourself the way `:terminal` shows one,
hand it to the terminal plugin: `require("@terminal").adopt(terminal, {
return_on_primary = true })` shows it in the focused view, sized for your
screen and typing into it, and with `return_on_primary` gives the view back
once a full screen program is done or the program exits. The terminal
stays yours to read and close. `references(buffer, { from, to, cwd })`
finds the files and lines some output names, and `row_marks` turns a
terminal's rows into marks for a buffer of your own.

### JSON-RPC

`greed.rpc.start(command, opts)` starts a program that speaks JSON-RPC 2.0
over its input and output, as language servers, debug adapters and coding
agents do. `opts.framing` is `"headers"` (`Content-Length` headers, the
default) or `"lines"` (one message a line, as ACP agents send them), and
`cwd` and `env` work as for `greed.process.run`. The program's requests go
to `on_request(method, params)`, whose return value is the answer (or `nil`
and an error message); its notifications go to `on_notify(method, params)`,
and `on_exit(stderr)` hears it end. Each runs in a coroutine of its own, so
one that waits doesn't hold up the rest.

```luau
local conn = assert(greed.rpc.start({ "my-adapter" }, {
	on_notify = function(method, params)
		greed.echo(`{method}: {greed.json.encode(params)}`)
	end,
}))
local caps, err = conn:request("initialize", { adapterID = "demo" }) -- waits for the answer
conn:notify("initialized", {})
```

`conn:alive()` says whether it still runs, `conn:stderr()` is what it
printed there lately, and `conn:close()` stops it. A request on a closed or
exited connection returns `nil` and why. The connection is your plugin's
and goes with it.

### Reading text with sikt

`greed.sikt` reads structure out of text, like a program's output or the
lines of a note, with [sikt](https://github.com/johnae/sikt/blob/main/docs/language.md)
patterns. A pattern reads like a sentence: literal text is quoted, `name:`
captures, and `integer`, `size` or `duration` captures come back as
numbers. Compile a program once and run it as often as you like:

```luau
-- du -h prints a size, a tab and a path a line.
local big = assert(greed.sikt.compile('find used: size 1+ space path: until text end where used > 1G'))
for _, row in big:rows(ran.stdout) do
	greed.echo(`{row.path}: {row.used} bytes`)
end
```

On a mistake, `compile` gives nil and the mistake in words. Programs that
work but probably don't do what was meant come with `warnings`.
`greed.sikt.check(source)` gives both, each with its `message`, `at` (where
in the program), `help` and whether it's only a `warning`, so a program
someone types can be shown with its mistakes marked.

Each line is matched on its own unless `lines = false`. `rows(text, { at =
true })` also gives where each match is (`from`, `to`, `line`). For a lot of
text, `rows_many(texts)` runs over a list of texts on other threads and
waits like `greed.sleep`. Its rows become Luau tables all at once when it's
done, so give it a few hundred texts at a time. `replace(text)` rewrites the matches as the
program's `replace` says. Rules can live in Luau and be used by name:

```luau
local notes = assert(greed.sikt.compile('use "notes" find link or tag', {
	modules = {
		notes = [[
			let link = "[[" target: until "]]" "]]"
			let tag = not after wordchar "#" tag: 1+ wordchar
		]],
	},
}))
```

### The shell

`require("@shell")` is the [shell](shell.md): `shell.run(sh, line)` runs
a line in a shell as a new block, `shell.of(buffer)` is the shell a buffer
shows, `shell.project()` the project's shell (opened out of sight when
there's none), and `shell.wait(block)` waits for a block to finish.
`shell.change(sh, block, line)` runs a line in a block's place instead,
stopping it first if it runs, as `space C` does. A block's
record has what ran and how it ended, its output, and `block.value` when
the output was JSON.

`shell.run(sh, line, opts)` takes, all optional: `cwd` and `env` to run
with in place of the shell's, and `runner = "pipe"` to keep what the
program prints (`block.stdout`) apart from its errors (`block.stderr`);
the default runs it in a terminal, as a line you type. Leave out `by`:
`by = "agent"` is for agents' tools, and marks the block as an agent's.

```luau
local greed = require("@greed")
local shell = require("@shell")

local block = shell.run(shell.project(), "go test -json ./...", { runner = "pipe" })
if block then
	shell.wait(block)
	greed.echo(`{block.status}: {#block.stdout} bytes`)
end
```

The programs a line runs are your plugin's, so it needs `proc`; the
builtins `cd` and `open` also need `fs.read`. What the shell does around
them, like its wrapper's files in the cache folder, its history, the
folder's environment and the prompt, is the shell's own, so they need
nothing more. A block that can't start, say for a missing capability,
ends as failed with the reason in `block.stderr`.

`block.table` is the output read as a table, when it was one: `columns`
(the header's names, in order) and `rows`, each a map from a column's name
to its cell's text. `shell.tables` reads and works on them:
`tables.detect(text, command)`, `tables.from_value(json)`,
`tables.where(tbl, "AGE < 1h")`, `tables.select(tbl, "NAME,AGE")`,
`tables.sort(tbl, "AGE -r")` (each a new table), `tables.number("512Mi")`,
and `tables.draw(tbl)` lines it up as text; `tables.columns(text, true)`,
`tables.csv(text)`, `tables.from_json(text)`, `tables.split(text, ":")`
and `tables.lines(text)` read text that's known to be a table.

`greed.compare` compares values the way `where` and a view's filter do,
so your own filters read the same: `greed.compare.test("12 (5s ago)",
">", "0")`, `greed.compare.test("WARN", ">=", "warn")`,
`greed.compare.number("512Mi")`, `greed.compare.order(a, b)` (-1, 0 or 1,
for sorting) and `greed.compare.find("AGE<=1h")` for where an operator is.
`greed.text.shape(line, true)` reads a line of nested text (YAML, indented
JSON, `kubectl describe`) as filters and folds do: how far it's indented,
a list item's `- ` counting, and the key it starts with.

For writing text the way the rest of Greed does, `require("@core")` has
`text.width(s)` (cells on screen, wide characters two), `text.clip(s, n)`,
`text.split_lines(s)`, `text.trim(s)`, `text.unquote(s)` and
`text.bytes(n)` ("142.6 kB"), and `time.age(seconds)` ("3d", as kubectl
writes an age), `time.ago(seconds)` ("4 min ago"), `time.duration(ms)`
("0.31s", "2m 05s"), `time.iso(text)` (ISO 8601 to seconds) and
`time.iso_text(seconds)`.

A plugin that keeps a buffer's lines (to read them often without asking
the buffer) gets them with `text.buffer_lines(text)`, and after each
`buffer.changed` brings them up to date with `text.relines(buffer, lines,
starts, event.from_line, event.to_line)`, which reads only the lines that
changed: an edit costs what it changed, however long the buffer.

`shell.parser(match, parse)` reads the output of the commands `match`
names as tables, ahead of the shell's own look for one: a program's name,
or a pattern for the command line. `parse` is a
[sikt](#reading-text-with-sikt) program, whose captures are the columns,
or a function: `parse(text, block)` returns a table, a list of objects as
JSON has them, or nil to leave it to the shell.

```luau
local shell = require("@shell")

-- `terraform state list` prints one address a line.
shell.parser("^terraform state list", 'address: (type: until "." until text end)')

-- A function, for output a pattern can't say.
shell.parser("^mytool status", function(text)
	local ok, found = pcall(greed.json.decode, text)
	return if ok then found.items else nil
end)
```

`shell.row_at(sh, block, pos)` is the row under a position in the
buffer, filtered and sorted as the block shows it, for actions on a row:

```luau
local shell = require("@shell")

greed.command({
	name = "pod-logs",
	run = function(ctx)
		local sh = shell.of(ctx.buffer)
		local pos = ctx.view:cursor()
		local block = sh and shell.block_at(sh, pos)
		local row = block and block.table and shell.row_at(sh, block, pos)
		if sh and block and block.table and row then
			shell.run(sh, `kubectl logs {block.table.rows[row].NAME}`)
		end
	end,
})
```

`shell.completer(name, complete)` completes program `name`'s arguments
at a shell's prompt, ahead of Cobra, fish, carapace and the program's
help. `complete(request)` gets the command's `words` (the program first,
the word being completed last), its `line` so far, the `cwd` and `env` it
would run with, and `explicit` (you pressed `tab`), and returns candidates
as text or `{ text, detail }`, or nil to leave it to the other sources. It
can run programs; `shell.run_source(name, argv, cwd, env)` runs one the
way the shell's sources do, stopped by a newer run of the same name and
by `shell-completion-timeout`.

```luau
local shell = require("@shell")

-- `deploy ENV`: the environments are the folders under deploy/.
shell.completer("deploy", function(request)
	if #request.words ~= 2 then
		return nil
	end
	local found = {}
	local entries: { greed.DirEntry } = greed.fs.list(request.cwd .. "/deploy") or {}
	for _, entry in entries do
		if entry.dir then
			table.insert(found, { text = entry.name, detail = "environment" })
		end
	end
	return found
end)
```

`shell.segment(name, provider)` puts a piece in every shell's prompt
before its folder, after the shell's own (the git branch and the project
environment) and those added before it, like the kubernetes plugin's
context. `provider(ctx)` gets the `shell`, its `cwd` and the `env` its
programs get, and returns `{ text, style, warning }` or nil for nothing;
`warning = true` turns the prompt's `❯` red too. It runs in the background
when a shell opens and after each command, so it can run a program; the prompt shows the new pieces once every
segment is done. With `shell-prompt` set to `starship`, starship draws the
prompt instead, and segments only add their warnings.

```luau
local shell = require("@shell")

-- The AWS profile in use, from the shell's variables.
shell.segment("aws", function(ctx)
	local profile = ctx.env.AWS_PROFILE
	if profile == nil then
		return nil
	end
	local production = string.find(profile, "prod") ~= nil
	return {
		text = `aws:{profile}`,
		style = if production then "shell.segment.warning" else "shell.segment",
		warning = production,
	}
end)
```

`shell.segment_icon(name, { plain = "☁", nerd = "\u{f0c2}" })` gives a
segment an icon for `shell-icons` to pick, and `shell.icon(name)`
is the one in use, to start the segment's text with.
`shell.production(context)` says whether a context matches
`shell-production-contexts`.

`require("@vcs").branch(dir)` is the branch of the repository a folder is
in, as the status line shows it, and the vcs plugin has the prompt show it
too. `shell.branch_finder(find)` does that: the git segment shows what
`find(dir)` returns for the shell's folder instead of the branch
`.git/HEAD` names.

`shell.environment(name, provider)` adds a kind of [project
environment](shell.md#project-environments), like devenv's, for
`shell-environments` to name. `provider.root(dir, env)` says which folder's
environment applies in `dir`, or nil, with a reason when there's one it
won't load ("not allowed"); it runs after every command, so keep it quick.
`provider.load(root, env)` loads it and returns `{ vars, watch, output }`:
the variables to set (a string) or leave out (`false`), the files whose
change loads it again, and what loading printed. It can run programs and
wait; an error says why it failed.

```luau
local greed = require("@greed")
local shell = require("@shell")

-- A folder with a .env file brings its NAME=VALUE lines.
shell.environment("dotenv", {
	root = function(dir)
		return if greed.fs.stat(`{dir}/.env`) then dir else nil
	end,
	load = function(root)
		local vars = {}
		for _, line in string.split(greed.fs.read(`{root}/.env`) or "", "\n") do
			local name, value = string.match(line, "^([%w_]+)=(.*)$")
			if name and value then
				vars[name] = value
			end
		end
		return { vars = vars, watch = { `{root}/.env` }, output = "" }
	end,
})
```

`:set shell-environments "devenv dotenv"` then asks devenv first.

`shell.stage(spec, run)` adds a [table stage](shell.md#filtering-and-tables)
like `where`. `spec` has its `name`, `usage` and `doc` (for `help` and
completion), `args` ("column", "columns", "condition" or "format", for
completion), and `starts = true` when it may follow a program too, as in
`kubectl get pods | NAME`; give that only to names no program has.
With `text = true` it takes text that isn't a table too, as a table of
its words (columns 1, 2 and so on, or a first line without numbers as
the header). `run(tbl, rest, ctx)` gets the table, the rest of the
stage's words, and `ctx.block` and `ctx.shell` when it runs in a shell
(a watch runs it each time, in the same block, so it can keep things
from run to run), and returns a new table (`{ columns, rows }`, each row
a map of column to text), text (which ends the stages, as `to csv`
does), or nil and why it can't. The `chart` stage is a plugin, written
this way.

`require("@scene")` draws small vector scenes in character cells, as
charts are: `scene.cells(spec, cols, rows)` gives styled lines, braille
for lines and dots, eighth blocks for filled shapes. A spec is
`{ alt = "what it shows", items = { ... } }`, with coordinates in cells;
items are `line`, `area`, `rect`, `dots`, `text` and `group` (clipped).
`require("@chart").lines(tbl, "bar CPU", cols, rows)` draws a table as
`| chart` would.

To have clients draw a scene better than characters, keep it with
`greed.scene.new(spec)`, which gives its id, and put it over the
characters with a mark's `scene = { id = id, cols = 60, rows = 12 }`.
The window and terminals with kitty graphics draw the scene as an image
under their text, so the scene's own text stays text; other clients show
the characters. `require("@scene").drawn()` says whether to place
scenes at all (the `scene-drawing` option). `greed.scene.set(id, spec)` changes it, and
`greed.scene.forget(id)` lets it go; a plugin's scenes go when it does.

```luau
-- `top COL N`: the N rows with the most in a column.
shell.stage({ name = "top", usage = "top COL N", doc = "The rows with the most in a column", args = "column", starts = true }, function(tbl, rest)
	local name, count = string.match(rest, "^(%S+)%s*(%d*)$")
	local column = name and shell.tables.column(tbl, name)
	if column == nil then
		return nil, "top COL N, like top RESTARTS 5"
	end
	local rows = shell.tables.sorted(tbl, shell.tables.all(tbl), column, true)
	local kept = {}
	for i = 1, math.min(tonumber(count) or 10, #rows) do
		kept[i] = tbl.rows[rows[i]]
	end
	return { columns = tbl.columns, rows = kept }
end)
```

`shell.builtin(spec, run)` adds a command the shell runs itself, ahead of
programs and aliases of that name (`^NAME` still runs the program).
`spec` has `name`, `usage`, `doc` and `args` as builtins have them.
`run(args, ctx)` gets the words after the name, and `ctx` with the `shell`,
the `block`, its `cwd`, and `write(text)` and `error(text)` to print in
the block; it returns the exit code, 0 when it returns nothing, and an
error fails the block with its message. It can wait, as commands can;
ctrl-c ends its block at once, after which what it prints goes nowhere and
`ctx.stopped()` says so, for one that waits in steps to quit early.
Neither can replace the shell's own, and both go when the plugin does.

`shell.kind(spec)` says what the rows of some commands' tables are, so
they're [things to act on](shell.md#rows-you-can-act-on) like any other
(`core.actions`). `spec.match` names the commands as `shell.parser` does.
`spec.columns` lists columns a table must have (in any case); without
`match`, the kind reads any table with them, whatever printed it, after
the kinds naming the command had their turn. A `PID` column is how `ps`
on Linux and macOS, nu's `ps`, `lsof` and `docker top` all become
processes.
`spec.capture(block, shell)` runs once as the block finishes and keeps
what the rows can't say themselves, like the context a command ran
against; returning nil says the block isn't this kind's after all.
`spec.row(row, captured, block)` gives `{ kind, label, value, key, cells }`
for a row (its cells by column, `cells` the things some of them are, by
column, like a pod's `NODE`), and `spec.called(captured, block)` what one row
and several are called in the block's status ("pod", "pods"). Rows then
take the actions of their kind, whoever added them; `ls -l` rows are
`file` things, so every file action works on them.

`key` names the thing as an [object](#objects), `kind:key`: the same for
the same thing in any block, like a pod's context, namespace and name.
Without one, a value that's a string (a file's path) names it, and rows
that can't be named are plain rows of their block. The plugin that knows
the things says what they are with `core.objects.kind({ name, doc })`;
the shell is a source of objects of every kind: rows are listed from
every shell's blocks, the newest first, inspected with the row's cells
(`row`) and related to their block, whoever's kind they are. Leave the
kind out for one the editor has already, like `file`.
`fresh = shell.fresh(function(value) return "ps -p " .. value.pid end)`
on the kind lets `watch` see a thing as it is now: the command line that
lists just it runs where the row came from, and its first row is the
thing's state. `shell.env_of(value)` is the variables of the block a
thing's row came from (its `KUBECONFIG`), to ask a program about it as
that block would. `shell.log_prefix(read)` teaches the log view a prefix
a program puts before merged lines, like kubectl's `[pod/api-1/app] `:
`read(text)` returns the fields it says and the rest of the line, or nil.

`spec.complete` makes the rows complete later commands. It maps a
program's name to a function given the command's words (the word being
completed last) and the shell; it returns nil when no thing of this kind
fits there, or a function giving the word to put in for a thing's value,
nil for one that doesn't fit (from another context, say). The rows of
the newest blocks come first in the menu, before what the program
offers itself.

`spec.streams(words)` says whether a command line of the kind keeps
printing rows again as they change, as `kubectl get pods -w` does. The
shell then reads it through a pipe and shows each row once, in its place,
known by its first cell (its first two under a `NAMESPACE` column).

`spec.order` lists the columns to show first, the most useful first. A
narrow pane cuts a table's rows at its right edge, so a program that
prints what its rows are known by last (docker's `NAMES`) gets its table
redrawn with these columns first, and the others follow as they came.
Only the screen changes: the block's output keeps what the program
printed, and columns picked with `select` stay as picked.

`shell.action_command(kind, name, command, opts)` adds an action that runs
a command as a block in the shell, so what it does is there to read and
run again. `command` is a template whose `{field}`s are the thing's
value's fields, quoted, or a function from the value to the line.
`opts.doc` says what it does, `opts.danger` makes it ask first (saying
when the value's `context` is a production one), `opts.default`
makes it what `enter` on such a row does, and `opts.follow` opens the
block of a command that keeps printing (`logs -f`) in a float following
its last line. Run while the same command still runs in that shell, an
action opens that block instead.

```luau
-- `systemctl list-units`'s rows as services.
shell.kind({
	name = "systemd",
	match = "^systemctl list%-units",
	row = function(row)
		local unit = row.UNIT
		if unit == nil or not string.match(unit, "%.service$") then
			return nil
		end
		return { kind = "service", label = unit, value = { unit = unit }, key = unit }
	end,
	called = function()
		return "unit", "units"
	end,
})
core.objects.kind({ name = "service", doc = "A systemd service, by its unit" })
shell.action_command("service", "status", "systemctl status {unit}", { doc = "How it's doing", default = true })
shell.action_command("service", "restart", "sudo systemctl restart {unit}", { doc = "Restart it", danger = true })
```

## Queries and indexes

Greed has one query language for searching and filtering, and a plugin's
own lists can speak it too: words, `field:value`, comparisons, `-` and
`OR`, dates like `date:2w..` and `due:..eow`, `is:` flags, and `in:`,
`under:` and `has:` for what sits where. Words and values match without
minding case or accents, so `cafe` finds `Café`.

```text
from:anna is:unread date:2w..
is:todo -is:done due:..+7d in:(tag:garden) sort:due
```

`require("@core").query` reads one and runs it. A source says what its
items' fields are (`"text"` by words, `"exact"` as whole values,
`"value"` compared as `greed.compare` does, `"date"`), which flags `is:`
knows, and where items sit:

```luau
local core = require("@core")
local query = core.query

local tasks = {
	{ title = "water the plants", due = "2026-10-16", done = false },
	{ title = "buy seeds", due = "2026-10-12", done = true },
}

local source: core.QuerySource = {
	fields = {
		title = { kind = "text", get = function(t) return t.title end },
		due = { kind = "date", ahead = true, get = function(t) return t.due end },
	},
	flags = { done = function(t) return t.done end },
	text = function(t) return t.title end,
}

local parsed = query.parse("plants -is:done due:..eow")
local problems = query.check(parsed, source) -- fields and flags it hasn't, bad dates
local found = query.run(parsed, tasks, source) -- the tasks that match, sorted as asked
```

`parse` gives the problems with where they are in the text (`at`), and
`print(parsed)` writes a query back in its one form. `core.dates.span`
reads a date the way queries do ("last week", "2w", "eom").

An item can be in several places at once, as a mail is in each of its
labels. Name the field that holds them in the source (`places = "label"`),
and `in:inbox` finds the items with "inbox" there as well as those whose
parent is named so.

For many items, or items kept between sessions, put them in an index:
`greed.index.writer(path)` makes or opens one to write, and
`greed.index.open(path)` reads one another program writes. Give the source
a `key` for each item and say which flags are `stored`; the rest are
worked out when a query runs.

```luau
local index = greed.index.writer(dir .. "/tasks.db")
index:write(query.index_items(tasks, source))
local keys, maybe = query.search(index, parsed, source)
```

`search` gives the matching items' keys; `maybe` holds those that depend
on a flag that isn't stored, for the plugin to check. `index:items(keys)`
gives back what the index holds for them (name, text, fields, flags), to
show what was found. An index's methods work on another thread and wait
like `greed.sleep`.

### A search box

`core.search_box.open` asks for a query the way every search in Greed does.
It shows the query in colours as it's typed, with a dimmed `*` after the
word at the end, since that word matches by prefix until a space settles it.
Mistakes are underlined and said after the query, and the title says how many
results there are. With none, it also says which term to leave out to find
the most (`0 results · 12 without tag:home`). `tab` completes the source's
fields and flags, its `names` after `in:`, and `values` after `field:`. `up`
and `down` bring back queries submitted before in boxes with the same
`history`. A source with `names` also gets an error when `in:` names
nothing there ("nothing here is named garen; did you mean in:garden?").

```luau
core.search_box.open({
	title = "Search tasks",
	source = source,
	history = "tasks",
	values = function(field)
		return if field == "tag" then { "garden", "home" } else {}
	end,
	count = function(parsed)
		local found = query.run(parsed, tasks, source)
		return if found then #found else nil
	end,
	on_change = function(text, parsed) end, -- show the results as it's typed
	on_submit = function(text, parsed) end,
})
```

With `regex = true`, a query starting with `/` is a regex for the rest, as
the shell's filters take it, and `words` adds words of the plugin's own to
what `tab` offers.

### Searched with everything else

`core.everywhere` is the search over everything that's yours (`space n s`
and the agents' `search_everywhere`). A plugin that keeps the person's
things adds itself as a source. Its `search` gets the query with its own
`in:` taken out and gives back what it found:

```luau
core.everywhere.add({
	name = "tasks",
	doc = "Your tasks",
	search = function(text, limit)
		local hits = {}
		for _, t in query.run(query.parse(text), tasks, source) or {} do
			table.insert(hits, {
				source = "tasks",
				kind = "task",
				id = `task:{t.title}`,
				label = t.title,
				at = os.time() * 1000, -- when, in milliseconds, to sort by
				open = function() greed.echo(t.title) end,
			})
		end
		return hits, nil -- or nil and why it couldn't search
	end,
})
local hits, troubles = core.everywhere.search("plants in:tasks")
```

Hits from every source come newest first, those without `at` last. A
source that fails says why in `troubles`, and the others still answer.

## The command line

`greed.cli({ name, doc, usage, run })` adds a command to `greed` itself.
`greed NAME ARGS` starts an editor with no screen, with your plugins and
config, and calls `run` with the arguments. It can wait like any command
(on `greed.process.run`, `greed.http.request`, `greed.sleep`); what it
echoes is printed as it goes, what it returns is printed at the end, and
an error makes `greed` exit with a failure.

```luau
greed.cli({
	name = "hello",
	doc = "Say hello",
	usage = "[NAME]",
	run = function(args)
		return `hello {args[1] or "there"}`
	end,
})
```

`greed hello world` prints `hello world`, and `greed commands` lists it.
Names are lowercase words with dashes; a file of that name in the current
folder wins, and `greed NAME` with no such command opens `NAME` as a file.

## The network

`greed.http.request({ url, method, headers, body, timeout })` returns the
whole response (`status`, `headers` with lowercase names, `body`), or nil
and why. `greed.http.stream(...)` returns once the status and headers are
in, and `stream:read()` gives the body piece by piece as it arrives, which is how
model APIs stream their answers:

```luau
local stream, err = greed.http.stream({
	url = "https://api.example.com/v1/generate",
	headers = { ["content-type"] = "application/json" },
	body = greed.json.encode({ prompt = "Hello", stream = true }),
})
if stream == nil then
	error(err, 0)
end
while true do
	local piece = stream:read()
	if piece == nil then
		break
	end
	greed.echo(piece)
end
```

`stream:read(ms)` gives up after `ms` milliseconds with nil and `"timed
out"`, leaving the stream open, and `head_timeout = ms` limits the wait for
the status and headers; `timeout` limits the whole request, body included.

Each request runs on a thread of its own and both wait like `greed.sleep`,
so they work in commands and event handlers and never hold up the editor.
A plugin needs `net`, or `net:HOST` for each host it talks to.

Redirects are followed on the same host, never from https to http, so
headers like an API key only go where they were meant to. Any other
redirect comes back as the response, its `location` header saying where.

To download a file, give `request` a `save` path: a successful (2xx)
response's body is written there as it arrives, with no size limit, and
the file appears only once it's whole. Any other response comes back with
its body as usual and nothing is written. Saving needs `fs.write` too.

```luau
local got, err = greed.http.request({ url = url, save = cache .. "/grammar.wasm" })
if got == nil or got.status >= 300 then
	error(err or `status {got.status}`, 0)
end
```

Keys for those servers come from `greed.secrets.get("anthropic")`, never from
config or plugin source. It looks in the environment (`GREED_SECRET_ANTHROPIC`,
or the usual `ANTHROPIC_API_KEY`), then the system keyring, then Greed's own
secrets file, and waits like the rest. When it finds nothing and the
keyring couldn't be reached (`secret-tool` isn't installed, there's no
D-Bus session), it returns nil and why, since the keyring may have it.
`greed.secrets.set` keeps a secret in the file when the keyring can't be
reached, and the place it returns says why. A plugin declares each secret it
reads as `secrets:NAME`, and Greed's file APIs refuse to read the secrets file
itself.

## Models

The `models` plugin talks to language models. A plugin asks for a role, like
`fast`, and the user's config decides which model plays it:

```luau
local models = require("@models")
local stream, err = models.stream("fast", {
	system = "Answer in one sentence.",
	messages = { { role = "user", content = "What is a rope data structure?" } },
})
if stream == nil then
	error(err, 0)
end
while true do
	local piece = stream:next()
	if piece == nil then
		break
	end
	greed.echo(stream.text)
end
```

`models.ask(role, request)` waits for the whole answer instead.
`models.decide(role, state, questions)` asks yes-or-no questions about a
state and gives, for each by name, how likely yes is, from 0 to 1:

```luau
local answers = models.decide("decision", { command = "rm -rf build" }, {
    harmful = { instructions = "Could it do harm?", yes = "it may", no = "it can't" },
})
if answers and answers.harmful > 0.6 then ... end
```

A decision model, like Berget's System One models, answers these
directly; any other model is asked in a chat for the same answers, so
either kind can play the role. Both wait
like the rest of the API. The roles that come set up are `fast`,
`reasoning` and `local`; a plugin can ask for any role, and the user maps it
in their config or in `:models`.

A role of your own can use another role's model until the user sets one,
and `:models` lists it with the model it uses then:

```luau
models.fallback("summary", "fast", "summaries of long notes")
models.playing("summary") -- "fast" until models.roles.summary is set
```

Before asking, `models.check(role)` says what's missing without sending
anything: no model plays the role, its provider isn't set up, or it has no
key. `models.no_key(provider, why)` is the message every feature shows for a
missing key, naming the variable that sets it and `:models`; pass the
`why` `greed.secrets.get` gave and it says the keyring couldn't be reached.

For a model that calls tools, `models.turn(role, request, on_text)` runs
one turn: `request` has the conversation as `said` (each `{ role = "user",
text = ... }`, `{ role = "assistant", text = ..., calls = ... }` or `{ role =
"tool", call = ID, text = ... }`), `tools` (each a `name`, a
`description` and a JSON schema as `input`) and an optional `system`.
`on_text` gets the answer's text as it arrives, and the turn comes back as
its `text`, the `calls` it asks for (`id`, `name`, `input`) and `stop`:
`"done"`, or `"tools"` when it wants them run and their results sent in the
next turn. A fourth argument, `on_open`, gets a function that closes the
answer's stream once it starts, to stop it early (a closed stream ends the
turn with what came so far). It works the same with Anthropic and with
servers that speak OpenAI's chat completions. A user's turn can carry `images`, a list of PNG
file paths read when the request goes out; `models.sees_images(role)` says
whether the role's model can see them, and they're left out for one that
can't.

### Providers you sign in to

Some plans come with an account instead of an API key, like Berget Code.
A provider like that names a login, and `:login NAME` signs you in with
OAuth's device flow: Greed shows a link and a code, you approve it in a
browser on any device, and the tokens are kept with your other secrets and
renewed before they run out. Once you're signed in, the provider sends the
token instead of its key.

Add one in your `init.luau` or a plugin, from what the provider's sign-in
server says about itself (its OpenID configuration usually lists the two
endpoints):

```luau
local models = require("@models")

models.login.logins.acme = {
	title = "Acme AI",
	device_url = "https://auth.acme.example/oauth/device/code",
	token_url = "https://auth.acme.example/oauth/token",
	client_id = "acme-cli",
	scope = "openid offline_access",
}
models.providers.acme = {
	kind = "openai",
	url = "https://api.acme.example/v1",
	login = "acme",
	-- Optional: a key to use when you aren't signed in.
	secret = "acme",
}
models.roles.agent = { provider = "acme", model = "acme-large" }
```

That is how your config does it. A plugin gets other plugins' modules
read-only, so it adds the provider and the role with
`models.provider("acme", { ... })` and `models.role("agent", { ... })`;
both go when the plugin does. Adding a login works the same from both.

Then `:login acme`, and `:models` says "signed in (Acme AI)". `:logout acme` forgets
the tokens, and the provider goes back to its key. The name is used for the
secret the tokens are kept in, so it takes lowercase letters, digits and
dashes. Once a login is added it can't be replaced or changed, and its
tokens stay inside the models plugin: no plugin can read them or send them
elsewhere.

A sign-in that ends with a plain API key, as Mistral's Vibe does, has no
device or token addresses: `key` names the secret it keeps the key as, and
`get_key(show)` signs in, calling `show({ url = ..., minutes = ... })` with
where to go, and returns the key, or nil and why. Signing out forgets the
key, unless it's been replaced since.

Any plugin can add a provider, so a key or a sign-in goes only where the
user let it: the built-in providers' keys to their own servers, and any
other the first time it would go somewhere new, after Greed asks
("Send your acme key to https://api.acme.example from now on? Type yes to
allow it"; anything but `yes` says no). The answer is kept, so each key
and address asks once.

`scope` needs whatever the server wants for a refresh token, often
`offline_access`; without one, you'd sign in again whenever the token runs
out. Tokens are renewed with OAuth's own refresh at `token_url`. A provider
that renews another way gives a `renew` function, which gets the tokens
(`access`, `refresh`, `expires` in seconds like `os.time()`) and returns new
ones, or nil and why. Berget's posts the refresh token to its own API,
like this:

```luau
renew = function(tokens)
	local status, answer = models.login.post(
		"https://api.acme.example/v1/auth/refresh",
		{ refresh_token = tokens.refresh },
		"json"
	)
	if status ~= 200 or type(answer.token) ~= "string" then
		return nil, `Acme said {status}`
	end
	return {
		access = answer.token,
		refresh = answer.refresh_token or tokens.refresh,
		expires = os.time() + answer.expires_in,
	}
end,
```

`models.login.post(url, body, "form" | "json")` sends a POST and returns
the status and the answer decoded from JSON. Only the device flow is
supported for signing in; a provider that only signs in through the browser
on your own machine can't be added this way yet.

## Keeping state in one place

Some plugins keep state that has to live in one place: accounts, a store,
programs keeping them in sync. Chat, mail and Hoard work like that. Such a
plugin offers a service: one session, the owner's, holds the state, and
every session shows it and acts on it through views. Like this, a counter
you can add to from any session:

```luau
local greed = require("@greed")
local service = require("@service")

-- The service, and when its owner starts: when a view first needs it.
service.define({ name = "counter", start = "use" })

-- The owner: this part runs only in the service's own session.
if service.owner("counter") then
	local count = 0
	local offer: service.Offer
	offer = service.offer("counter", {
		version = 1,
		handle = function(method: string, params: any): (any, string?)
			if method == "get" then
				return { count = count }
			elseif method == "add" then
				count += params.by
				offer:notify("count", { count = count })
				return { count = count }
			end
			return nil, `no {method}`
		end,
	})
end

-- A view: the same in every session, the owner's too.
local shown = 0
local counter = service.use("counter", {
	version = 1,
	topics = { "count" },
	on = function(_, params: any)
		shown = params.count
	end,
	-- Called whenever the view connects, first or again: show what's there now.
	reset = function(view: service.View)
		local now = view:request("get")
		if now then
			shown = now.count
		end
	end,
})

greed.command({
	name = "counter-add",
	run = function()
		local _, why = counter:request("add", { by = 1 })
		if why then
			greed.echo(why)
		end
	end,
})
```

The owner runs in a session of its own, `counter.service`, so a stuck
service only takes itself down. Greed starts it when a view first asks,
and starts it again if it goes while a view listens. Nobody starts it by
hand; it shows in `greed ls` and `space P`, marked as a service. A plugin
like this lists `service` in `requires`.

| Call | |
|---|---|
| `service.define({ name, start })` | There's a service called `name`. `start` is `"use"` (when a view first needs it), `"always"` (when Greed starts) or a function saying whether to start it then. Two can't share a name |
| `service.owner(name)` | Whether this is the owner's session. Put the owner's half behind it |
| `service.offer(name, { version, handle })` | Answers views: `handle(method, params, caller)` returns a result, or nil and why, and may wait. `caller.session` is the session that asked |
| `offer:notify(topic, params)` | Tells views listening to `topic` that something changed. A topic is any name you pick |
| `service.use(name, { version, topics, on, reset })` | A view in this session. `on(topic, params)` hears changes; `reset(view)` runs each time it connects, so fetch what you show there |
| `view:request(method, params, { timeout })` | Asks the owner and waits (30 seconds by default): the result, or nil and why. Only where code may wait |
| `view:listen(topic)`, `view:ignore(topic)` | What it hears from now on |
| `view:state()` | `"idle"` (not needed yet), `"connecting"`, `"ready"` or `"unreachable"`, with since when and why |

A view connects the first time it's needed; in the owner's own session
it's ready as soon as the service is offered. Changes only reach it while
it's connected, so after a lost link nothing is caught up; `reset` runs
and the view fetches again. When the owner and a view speak different
`version`s, requests fail saying which to restart, and `:service-restart
NAME` starts a service's session again with the greed you run now.

`handle` runs as your plugin's own, as your event handlers do: only your
capabilities count, whichever plugins passed the request on. A registry of
your own does the same for what plugins hand it with
`greed.plugin.handler(f)`.

Answers go as JSON, so a service sends data, never a path on its machine.

## Agents

Plugins can offer tools to agents. A tool shows up for every agent: those
connected through `greed mcp` (Claude Code, Codex, Gemini CLI, opencode or
any MCP client), the agents Greed runs over ACP, and Greed's own agent, and
as `greed ctl NAME` in the shell:

```luau
require("@agent").tool({
	name = "word_count",
	description = "How many words the current file has",
	run = function()
		local _, words = string.gsub(require("@greed").view():buffer():text(), "%S+", "")
		return tostring(words)
	end,
})
```

A plugin offering tools lists `agent` in `requires`. The tool's parts:

| Field | |
|---|---|
| `name` | Letters, digits, `_` and `-` |
| `description` | What it does, for the agent deciding whether to use it. Say when to use it and what comes back |
| `input` | A JSON Schema for the arguments; `agent.schema.object({ path = { type = "string" } }, { "path" })` makes an object's, the second list naming the required ones. A call with an argument it doesn't name (unless `additionalProperties` allows any) or without a required one fails before `run`, saying what it takes. Left out, it takes none |
| `group` | The group it's offered with; left out, it's always offered (below) |
| `kind` | What it does beyond reading: `"edit"` (changes files or notes), `"execute"` (runs code or programs) or `"fetch"` (reaches the network); left out, `"read"` |
| `reviews` | `true` when the tool puts what it does in front of the user itself, as a proposal or a question does |
| `danger` | `danger(args)` says why a call is risky (`kubectl delete` "changes the cluster"), or nil; such a call asks the user every time, whatever they allowed |
| `sandboxed` | `true` when the tool does more than read but needs no say from the user, like checking a plugin in an editor of its own |
| `shell_only` | `true` keeps the tool for `greed ctl` and the programs Greed's shell runs, like `greed edit`: agents aren't offered it and can't call it |
| `run` | `run(args, caller)` does the work |

Greed's own agent asks the user before a tool whose `kind` isn't `"read"`
runs, the way it asks before its own edits, unless the tool `reviews` or
is `sandboxed`; MCP clients see the read-only ones marked read-only, and
their own permissions decide about the rest. Set `kind` on every tool that
changes, runs or fetches something, so it isn't run unasked.
A call whose `danger` says why waits for the user's yes every time, from
any agent, MCP clients included; only `greed ctl` skips it. For command
lines, `require("@core").risk.of(line)` says why one is risky, and
`risk.rule(program, function(words) ... end)` teaches it a program's,
as the kubernetes and docker plugins do for kubectl and docker. The other
way round, `risk.safe(line)` says whether every command in a line only
looks, or builds and tests, as auto mode lets agents run them, and
`risk.safe_when(program, function(words) ... end)` says which of a
program's commands are (all of them, without the function). See
[Permissions and sandboxing](permissions.md#what-always-asks) for how
the user sees these.

Agents connected when a plugin loads or unloads hear that their tools
changed, so a tool from a plugin you've just approved can be used in the
same conversation.

`run` gets the arguments as a table, and who called as `caller`, whose
`kind` is `"shell"` for `greed ctl`, `"socket"` for MCP clients through
`greed mcp` (agents Greed runs over ACP use it too), `"ide"` for Claude
Code's IDE connection and `"agent"` for Greed's own agent. Any plugin can
call a tool with any `caller`, so don't decide trust on `kind`: `agent.from_shell(caller)` says whether the call
came from `greed ctl`, whose user can run anything already.

A string `run` returns goes to the agent as it is, and any other value as
JSON, even a table with a `content` field. To answer with MCP's result
form itself, return `agent.result(content, is_error)`, where `content` is
text or a list of pieces like `{ type = "text", text = "..." }`. An error
goes back as an error, so `error("there's no file " .. path, 0)` tells the
agent what went wrong.

Hand text someone else wrote, like a web page or another agent's report,
back through `agent.untrusted(source, text)`: it goes between
`<untrusted-…>` tags the text can't close, with `source` saying where it
came from. Greed's agent and MCP clients are told once what the tags mean;
a model you ask yourself with `models.ask` needs `agent.untrusted_note` in
its system prompt. Secrets in the text (private keys, API tokens, values
named like passwords) are hidden first, and the tag says how many;
`agent.redact(text)` does that alone.

```text
<untrusted-3fa2c1b0e9d4 source="what `cat .env` printed" hidden="1 secret">
DB_HOST=db.internal
DB_PASSWORD=[secret hidden]
</untrusted-3fa2c1b0e9d4>
```

A buffer that shows what someone else wrote, like the mail plugin's
threads, can say so for its kind, and agents reading it with `read`, or
its selection with `focus`, get it between those tags:

```luau
core.outside.kind("mail-thread", "mail you received")
```

An agent is told what you're in with each message. A file says it by its
path; a buffer of your plugin can say in a few words what it is, which
`focus` and the inspector show too:

```luau
core.about.kind("mail", function(buffer)
	return `the mail list, searching "{query}", {#rows} shown`
end)
```

A tool can wait: for a process, a request, or the user. Changes to files
are best proposed, so the user reviews them first and the tool hears what
they decided:

```luau
local agent = require("@agent")

agent.tool({
	name = "add_license",
	description = "Propose adding the license header to a file",
	input = agent.schema.object({ path = { type = "string" } }, { "path" }),
	run = function(args)
		local text = require("@greed").load(args.path):text()
		local first = string.match(text, "^[^\n]*\n") or text
		-- Waits until the user has accepted or rejected it.
		return agent.propose(args.path, {
			{ old_text = first, new_text = "-- SPDX-License-Identifier: MIT\n" .. first },
		}, "add the license header")
	end,
})
```

`agent.propose_files` proposes changes to several files as one operation,
`agent.propose_ranges` does it by byte ranges (for edits from a language
server or a diff), and `agent.ask(title, questions)` asks the user and
waits for their answers. When an MCP client's connection closes while its
proposal waits, what's left of the proposal is rejected and the tool call
returns.

Each tool costs the agent tokens on every request, so a plugin with
several should put them in a group, which agents switch on with the
`tools` tool when they need it:

```luau
agent.group("todo-sync", "Syncing todos with the issue tracker")
agent.tool({ name = "issues_list", group = "todo-sync", description = "...", run = list })
```

The group's line is what an agent reads when deciding whether to switch it
on, so say what it's for. See [Agents](agents.md#tool-groups) for the
groups Greed has.

## Tests

```luau
local test = require("@greed/test")

test("greet says hello", function(t)
	t:run("greet", { "world" })
	assert(t:messages()[1] == "hello world")
end)

test("copy and paste at every selection", function(t)
	-- | marks each selection's head, ^ its anchor
	t:buffer("^ab| ^cd|")
	t:keys("y p")
	t:expect("ab^ab| cd^cd|")
end)
```

`greed test DIR` runs a plugin's tests, each in a fresh editor with the
default plugins loaded. Give it several folders (`greed test
runtime/plugins/*/`) to test several plugins at once. Tests run side by
side, as many at a time as the machine has cores, and the results are
printed plugin by plugin. A test file requires your plugin's other files
with `require("../log")` and gets the ones your plugin loaded, state and
all, so internals can stay out of what your plugin returns.

`greed check DIR` (or `greed check` in the plugin's folder) does what the
editor does before it trusts a plugin: strict type checking against
Greed's types and the other plugins', so `require("@theme")` checks too,
then the tests, then warnings like keys bound to commands that don't
exist. It needs no `.luaurc` in the plugin, so it suits a plugin with a
repository of its own, and its CI:

```yaml
- run: nix run github:johnae/greed -- check .
```

`t:keys("i")` presses keys and `t:type("hello world")` types text a
character at a time, newlines as `enter`. `t:draw(cols, rows)` and
`t:screen(cols, rows)` give what a client would show, as lines of text;
`t:frame(cols, rows)` gives the screen as the window draws it, to check
how it looks: its `rows`, the `images` and `scenes` (charts) placed and
the cells they cover, and `cell(col, row)` for a cell's text, size and
colors. `t:status()` the status line, `t:floats()` the floats' text and
`t:notices()` the desktop notifications sent; `t:clipboard_image(png)`
sets what `greed.clipboard.image()` gives. `t:ssh_agent_use(host)` acts
as a program asking to sign with your ssh key (it emits `ssh_agent.use`
and returns the request's id) and `t:ssh_agent_answer(id)` gives what
plugins answered. `t:wait(ms)` moves the clock
forward for code that sleeps, `t:wait_for(check)` waits for real until
`check()` is true (for a program's output; 15 seconds at most unless told
otherwise), and `t:tempdir(files)` makes a
folder of files to work on; `t:open(path)` opens one of them as
`greed.open` does, without your plugin needing `fs.read` for it.
Tests have no system keyring, so secrets go to the test's own file;
`t:keyring(program)` has a program stand in for `secret-tool` (one that
isn't installed acts as a keyring that can't be reached).
`local dir, git = t:repo("git", files)` makes a repository (jj or git)
with the files committed and returns a function that runs git there and
fails the test if it fails; `t:vcs("jj", dir)` gives that function for a
folder you set up yourself. `t:marked()` is the buffer with its markers,
and `t:quitting()`, `t:detached()` and `t:switched()` say whether
something asked the editor to exit, to let the client go, or to send it
to another session.

`t:run` waits for background work the command starts, but not for the
programs it reads from, like a shell block's: wait for those with
`t:wait_for`, checking what you're waiting for (`block.status ~=
"running"`, a picker's float). A message your command shows while it
waits is there before the program finishes, so it's not something to wait
for.

Each `t:tempdir(files)` call makes a new folder, so put every file a test
needs in one call. Files written from Luau aren't executable: to fake a
program, write it and make it runnable with `chmod`, then put its folder
first on a shell's `PATH`, as the docker plugin's tests fake `docker`:

```luau
local shell = require("@shell")

-- A shell whose `docker` prints a table for `ps`.
local function fake(t: test.TestContext): shell.Shell
	local dir = t:tempdir({
		["bin/docker"] = '#!/bin/sh\nprintf "CONTAINER ID   IMAGE   NAMES\\n3f2a1b4c5d6e   nginx   web\\n"\n',
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/docker` }))
	local sh = shell.open({ cwd = dir, show = false })
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	return sh
end
```

Tests don't show the message about code that held the editor up, so a
busy machine doesn't change what `t:messages()` returns. Each key a test
presses and each command it runs gets the time limit a key press gets in
the editor, and time spent waiting for programs and background work
doesn't count toward it.

`t` acts as the session's first client. `t:client(name)` adds another, as
if a second terminal attached, seeing what the first one does; it has
`keys`, `type`, `run`, `mouse`, `draw`, `screen`, `frame`, `status`,
`marked`, `expect`, `expect_mode` and `id`, all as that client:

```luau
test("each client has its own mode", function(t)
	t:buffer("|hello")
	local laptop = t:client("laptop")
	laptop:keys("i")
	laptop:expect_mode("helix-insert")
	t:expect_mode("helix")
end)
```

## Types

The API's types are in `runtime/types/greed`. `greed new` sets up a
`.luaurc` so `luau-lsp` in your editor and `luau-analyze --mode=strict`
check your plugin against it.

`greed reference DIR` writes the reference pages this site has, as
Markdown: every loaded plugin with its commands, keys and options, every
option, every event, and the whole API. With your config and plugins loaded, they
describe your own setup.

## Sharing a plugin

A plugin in a git repository of its own, with `plugin.toml` at the top,
installs with one line in someone's config:

```luau
require("@git-plugins").use("https://github.com/you/greed-leap")
```

Put its docs in a `docs` folder, as Markdown. Once the plugin is
installed, `:docs` and `space h d` list those pages after the manual's,
and `space h /` searches them. `README.md` comes first, then the others by
name, each titled by its first heading; a `SUMMARY.md` like this manual's
sets the order instead. Links and pictures relative to the page work in
the editor and on GitHub alike.

`greed check .` in its CI keeps it working as Greed changes, and
`greed = "0.4"` in `plugin.toml` keeps an older Greed from loading it.
[Plugins to install](plugins-to-install.md) lists plugins others can use,
and how to add yours.

## Loading and reloading

Greed loads the default plugins, then yours, then `init.luau`. Each plugin
runs in its own environment and owns what it registers: reloading a plugin
replaces its commands, keys, options, handlers and theme entries, and
`greed.plugin.unload(name)` removes them. Both also stop what the plugin
was running (its tasks from `greed.spawn`, and commands and handlers
waiting on a timer or a reply), clear the marks it set (in a namespace two
plugins write to, the marks belong to whichever set them last), close its
floats and panels, forget its images, stop its `greed.fs.watch` watches,
and put back the file types and language servers it replaced. A plugin
that runs too long is stopped, so a mistake in a loop can't hang the
editor.

What a plugin adds through another plugin goes with it too: its agent
tools, status line pieces, actions, features, styles, command line aliases
and the like. There's no need to pass your plugin's name or to clean up on
`plugin.unloaded`.

For what Greed doesn't know about, like a lock file you wrote or a process
another program keeps for you, hand `greed.plugin.cleanup` a function. It
runs when your plugin is unloaded or reloaded, like this:

```luau
greed.plugin.cleanup(function()
	greed.fs.remove(lock)
end)
```

It runs before your plugin's tasks are stopped, so don't wait in it: what
it starts stops with the rest. If it fails you see the error, and the
plugin still goes, with its other cleanups run.

### Keeping a registry of your own

A plugin that lets others add to it, like a list of handlers, uses the
same `greed.plugin.cleanup(remove)`. Called in the function others call, it
runs `remove` when the plugin that called it is unloaded or reloaded, and
returns that plugin's name. So what another plugin added goes with it.
Called from your own plugin, it runs when yours goes, which for a registry
entry does no harm. `greed.plugin.caller()`
just says who called. `require("@core").registry` makes the `remove`: `set`
puts a value in a table under a key, `put` adds to a list, and each returns
a function that takes the entry out unless it was replaced since. For an
entry you put in a list yourself, `remover(list, entry)` makes that
function. `tell(listeners, ...)` calls each one with `...`; one that fails
has its error shown and the rest still hear.

```luau
local core = require("@core")

local M = {}
local greeters: { [string]: () -> string } = {}

function M.greeter(name: string, greet: () -> string)
	greed.plugin.cleanup(core.registry.set(greeters, name, greet))
end
```

### Other plugins' modules are read-only

`require("@name")` gives a plugin a read-only view of another plugin's
module: reading works as usual, nested tables too, and setting anything
raises an error, so no plugin can replace another's functions or settings.
Offer functions for what others may change, as `core.style.typing_kind` or
`models.role` do. Your config, a trusted project's `.greed` folder, the
REPL and tests get the modules themselves, so the settings the docs show
you assigning, like `models.roles.fast = ...`, work there. Go through a
view with `for k, v in t do` and `#t`; `pairs`, `ipairs` and the `table`
functions don't see through it.

## Trying code

`:lua CODE` runs Luau in a scratch environment whose globals last, and
`:= EXPR` shows what an expression is. In any buffer, `space l e` runs the
selection, or the line the cursor is on, the same way, and shows what it
returned at the end of its last line (or the error); the next edit takes
it away, as while writing a plugin or your `init.luau`:

```luau
#greed.buffers()  -- space l e here shows how many are open, like  ⇒ 3
```

# Writing plugins

Everything you use in Greed is a plugin written against the API described
here, so the default plugins in `runtime/plugins` are the best examples:
`core` holds the editing commands, `helix` gives them Helix's keys, `grep`
is the project search, `agent` the MCP tools.

## A plugin

```text
~/.config/greed/plugins/greet/
  plugin.toml        name = "greet", what it may use
  init.luau          runs when the plugin loads
  test/greet.luau    tests, run with `greed test greet`
```

Run in `~/.config/greed/plugins`, `greed new greet` creates this, with a
working test and type checking set up.
`plugin.toml` can list plugins this one uses, like
`requires = ["core", "picker"]`; they load first and are available as
`require("@core")` and `require("@picker")`. A plugin's `init.luau`
requires its other files with `require("@self/name")`, and those files
require each other with `require("./name")`. A plugin can't require files
outside its folder.

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
you've approved them. Until then Greed says it waits, and
`:plugins-approve` shows each waiting plugin with what it asks for; choose
one to approve and load it. Approvals are kept per plugin folder in
`~/.local/state/greed/approved.json`, and a plugin that later asks for more
waits again. Plugins that use nothing beyond the editor load at once, and
installing a plugin an agent wrote approves it, since its review shows the
same list. Plugins can't write the approvals file through Greed.

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

Plugins are Luau, a typed dialect of Lua. If you know Lua, the differences
you'll meet are types (`local n: number = 1`), `if a then b else c` as an
expression, backtick strings with `{interpolation}`, `+=`, and `for k, v in
t do` without `pairs`.

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
usually means a typo. `greed.plugin.check` reports both as warnings.

Commands get a context: `ctx.buffer` and `ctx.view` where they run,
`ctx.args` from the command line (`:greet world`), `ctx.count` when a count
was typed, `ctx.keys` that ran it, `ctx.force` for `!` (as in `:q!`),
`ctx.char` for keys that type a character, and `ctx.client`, the
id of the client that ran it (see [Clients](#clients)). Keys for
commands people reach for by name go in the leader, `{ layer = "leader" }`,
which every editing style opens its own way (`space g` in Helix and Vim,
`ctrl-space g` in the vscode style). Keys for normal mode or for typing go to a
role, `{ role = "command" }` or `{ role = "typing" }`, so they work in
every style's mode for it, styles added later included; `{ style =
"helix", role = "command" }` is for one style's. Other keymaps are bound
per mode, or per kind of buffer with `{ kind = "tree" }`.
Bindings made later win, and `greed.keymap.unbind` and `greed.keymap.clear`
take keys away, so a plugin can rebuild a mode from scratch. A mode is a
name, and `greed.mode.set("visual")` makes one. `greed.keymap.inherit(mode,
parent, prefixes)` lets a mode use another's keys (some of them, with
prefixes), and `greed.keymap.enter(mode, keys, layer)` opens a layer with
keys, the way each style opens the leader; see [Editing
styles](editing-styles.md#making-your-own).
`greed.keys.record(name)` and `greed.keys.stop(name)` keep what's typed, for
macros and the like; several recordings can run at once. `greed.keymap.fallback(mode,
command)` runs a command for any single key nothing else takes (a mode
inheriting all of another's keys uses that one's), and
`greed.keymap.isolate(mode)` keeps keys bound for every mode out of one,
the way a terminal takes every key.

Keys bound for a kind of buffer alone work in every editing style and
every mode, ahead of the mode's own, so a panel binds them once, with
`{ kind = "tree" }`. A buffer kind you type into, like a prompt, says so
with `core.style.typing_kind("my-prompt")`: focusing one goes to the
style's typing mode, and `core.floats.typing` opens a float in it.
`core.style.label_kind("my-prompt", "rename")` has the status line call
the mode RENAME while one has focus, rather than the typing mode's name.
Rather than naming other styles' modes, ask `core.style`:
`is_typing()` says whether the current mode types (insert, Vim's insert,
the vscode style), `role()` which role the current mode plays, `mode_for(role)`
the style in use's mode for a role, and `each_typing(function(mode) ...
end)` calls back with every style's typing modes, including styles added
later, for modes of your own made from them, like the completion menu's.
Commands can carry tags others check:
`core.commands.tag("typing", { "my-type-char" })` keeps them out of the
selection history and in one undo step in the vscode style, and `"no-repeat"`
leaves them out of what `.` repeats.

For keys that should mean something in one buffer only for a while,
`buffer:set_keys({ y = "my-answer-yes", esc = "my-hide" })` binds single
keys for that buffer, in every mode and ahead of every other binding,
while it has focus; `buffer:set_keys(nil)` drops them. The agent pane uses
it to answer a question with `enter` or a letter whatever mode you're in.

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
(kind, name, command, doc).

The kinds Greed itself uses are `file`, `folder`, `link`, `symbol`,
`problem`, `change`, `button`, `text` (the selection) and `command`, and
the shell's rows add `process`, `container`, `pod`, `deployment` and
`shell-block`, so a plugin can add actions to those too. A plugin's finders and actions go
when it's unloaded.

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

`core.objects.find(buffer, pos, key, around)` finds the text objects every
editing style uses, by Helix's keys: `"w"` a word, `"p"` a paragraph, `"("`
the parentheses around `pos`, `"f"` a function from the syntax tree, and so
on. It gives `from, to, linewise`, or nil. `core.objects.pair(char)` is
what surround wraps text in for a key.

`view:cursor()` is the head of the primary selection and
`view:set_cursor(pos)` makes the selection one cursor there.
`require("@core").text.span(range)` gives a range's start and end,
whichever way it points. `buffer:line_text(line)` is a line without its
line break. `buffer:display_column(pos)` is the screen column `pos` is
drawn at, counting wide characters as two columns and tabs up to the next
tab stop, and `buffer:at_display_column(line, col)` goes back from a
column to a position, which is how up and down keep their column.

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
written (or gives nil, without opening it). Paths an agent or a user gives
a plugin are relative to the project, and `core.project` turns them into
full paths and back:

```luau
local core = require("@core")
core.project.resolve("src/main.rs")    -- the shown project's root/src/main.rs; ~ is home
core.project.resolve("a.rs", "/tmp/x") -- from another folder
core.project.relative(path)            -- "src/main.rs", or the full path outside the project
core.project.short(path)               -- like relative, but "~/..." under your home folder
core.project.tilde(path)               -- "~/src/greed" for a path in your home folder
core.project.basename(path)            -- "main.rs" for "src/main.rs"; nil for "/"
core.project.identity(root)            -- the repository's store, the same in all its workspaces
```

`core.file` reads and writes files the way you'd want an agent to:
`core.file.text(path)` is the text as you have it, unsaved changes included,
and `core.file.write(path, text)` goes through the open buffer, so undo takes
it back and the language server sees it, then saves; a closed file is
written to disk. `{ from, to }` replaces just that part, and `{ load = true }`
opens the file first. Both take paths as `core.project.resolve` does, and
`core.file.buffer(path)` is the open buffer for one.

A buffer of your own with no file, like a page of results or a command's
output, can be scratch: `core.file.scratch(buffer)` keeps its changes from
counting as unsaved, so `:q` doesn't refuse over them and the status line
shows no `[+]`, until it's saved as a file. `core.file.unsaved(buffer)` says
whether a buffer has changes to save. A buffer someone types into in turns,
like a prompt, can let go of its undo history with `buffer:clear_history()`,
so undo never reaches past the last turn. To tell someone how to set a
secret, `greed.secrets.variable("anthropic")` is the variable that does
(`ANTHROPIC_API_KEY`).

To show a file to the user, `core.file.open(path)` opens it in the main
view, as the picture for an image and the pages for a PDF, and
`core.file.open_at(path, line, col)` puts the cursor there too (0-based
line, byte column). `core.file.open_link(uri)` opens a web address with the
`link-opener` option or the system's opener. A plugin that shows some kind
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

For files on disk with no buffer, `greed.fs` has the usual operations, so
a plugin needs no `rm` or `mv`. Each returns `true`, or nil and why:

```luau
greed.fs.write(path, text)                        -- creates its folders too
greed.fs.write(path, text, { private = true })    -- readable only by you (0600)
greed.fs.mkdir(dir)                               -- and the folders above it
greed.fs.copy(from, to)
greed.fs.rename(from, to)
greed.fs.remove(path)                             -- a file, link or empty folder
greed.fs.remove(dir, { recursive = true })        -- a folder and all in it
greed.hash.sha256(text)                           -- hex, to tell if text changed
greed.hash.sha256_file(path)                      -- to check a download
```

Something already gone counts as removed. `remove` and `rename` raise an
error rather than touch the root folder, your home folder, a path with `..`
in it or a folder holding Greed's own approvals or secrets, so a path built
wrong can't take more than it should. `greed.fs.stat(path)` says what's
there: its `kind`, `size`, `mode` and when it was `modified` (seconds
since 1970). `greed.hostname()` is the machine's name.

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
`view:close()` closes it. `greed.view()` is the focused view, and the
shown tab's active pane is where `greed.open` opens files. Tab ids work
whichever project the tab is in: `greed.tab.switch` and `view:focus()` on a
tab or view of another project show that project.

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
  labels). It can also hide text (`conceal`, like a link's brackets), shown
  again as `reveal` says: `"line"` (the default) when a cursor is on its
  line, `"cursor"` when one is inside it, `"never"`, or `"auto"`, which
  follows the mode: on the cursor's line while typing, inside it in edit
  mode, never otherwise. Markdown and notes use `"auto"`, so their marks
  stay as they are when the mode changes (`greed.reveal(how)` is what core
  calls as it does). `buffer:decorate(ns, marks, { from = a, to = b })`
  replaces only the marks starting from `a` up to `b`, for plugins that
  draw again just the lines an edit changed. `plain = true` draws a mark's
  text without syntax highlighting, as for a tool's output in a Markdown
  buffer. A mark can fold lines away under the first one (`fold`),
  or show lines that aren't in the buffer under its own (`lines`), whole
  or in pieces with styles of their own. A mark's text with an `action`
  (a command name) is a button: clicking it, or `enter` on it in normal
  mode, puts the cursor at the mark and runs the command. `scale = 2`
  (up to 4) makes its text bigger, like a heading: each character takes
  twice the cells across and its row two rows down. The window draws it
  big, and so does kitty; other terminals show it at the normal size.
  `gutter` styles the line numbers of the lines a mark touches, and `data`
  keeps anything you like with a mark (plain tables, strings, numbers),
  given back by `buffer:decorations(ns)`.
  `buffer:marks_at(pos)` gives the marks over a place in every namespace.
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
  `require("@panes").floats.show(buffer)`, and say a buffer needs the
  user with `core.floats.attention(buffer, true)`.
- Pickers (`require("@picker").pick(title, items, choose, options)`)
  filter a list as you type, with an optional preview, or ask a function
  for items as the query changes. `on_move` hears each item as it becomes
  the current one and `on_cancel` hears `esc`, for trying things out live.
  With `paths = { dirs = true, choose = function(path) ... end }`, typing a
  path lists the folder's contents, and `tab` completes one into the query.
- The completion menu asks sources before the language server, in any
  buffer, a file or not: `require("@lsp").completion.source(function(view,
  ask) ... end)` returns items like `{ label = "src/", text = "src/", from
  = 12 }` (`from` is where the text it replaces starts; the word before the
  cursor by default), or nil to leave it to the next source. `detail`
  shows dimmed after the label and `badge` before it, a word saying whose
  it is (the shell's own things say `greed`). `ask.explicit` is true when
  you asked with `tab` or `ctrl-space` rather than by a pause in typing. A
  source can wait, for a program say; its answer is dropped if more was
  typed meanwhile. A second argument says how its menu behaves:
  `{ enter = "selected" }` has `enter` take only an item moved to while
  `completion-enter` is `auto` (`"first"`, the default, takes the first);
  `tab = "insert"` makes `tab` complete in place as a shell does (the only
  match or what all matches start with at once, then each item in turn);
  and `arrows = "after-tab"` leaves `up` and `down` to the buffer while a
  menu that opened by itself hasn't been moved into. The shell completes
  its prompt this way, with all three. A plugin that binds `tab`, `enter`
  or the arrows for typing in its own kind of buffer calls
  `completion.keys_over(kind)` so the menu keeps those keys while it's
  open.
- The theme maps style names to looks, as in
  `greed.theme.set({ ["my-plugin.match"] = { fg = "yellow" } })`. Use your own
  names so users can restyle them. Themes themselves go under those
  entries: `greed.theme.base(entries)` replaces the whole base, which is how
  the theme plugin switches themes.
- The status line is pieces you can add to or take away from with
  `require("@statusline").add` and `.remove`, or replace with `greed.statusline`.
  A piece returning `{ text = "3 due", action = "notes-agenda" }` runs the
  command when clicked, and `style = "ui.statusline.warning"` draws it as a
  warning.
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
  or all of them, again in full.

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

`greed.sleep(ms)`, `greed.next_key()`, `greed.process.run(...)`,
`greed.http.request(...)`, `greed.lsp.request(...)`, `greed.fs.grep(...)` and
`greed.plugin.check(...)` wait like this, and so do
`picker.choose(title, items)` and `core.prompt.ask(title)`, which give nil
when you close them. (`picker.pick` and `core.prompt.open` take callbacks
instead, for pickers that stay open while you work. `core.prompt.open`
returns the prompt's view, to put a label on its border, and its `kind`
option gives the prompt keys of its own, the way the vscode style's find bar
binds `enter` to the next match.) `greed.signal()` lets
one piece of code wait for a value another sends. `greed.animate(ms, step)`
calls `step(t)` once a frame, which is all the flash on copy is.
`greed.fs.watch(path)` makes a "file.changed" event come whenever that file
changes, from anywhere; it's how your config reloads.

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
with nothing pauses the same way on purpose. Your own coroutines, like a generator made with `coroutine.wrap`, are never
paused this way. One that works for a whole minute without finishing is
stopped and Greed says so. Code that can't be paused, like a status line
piece or a plugin's top level, is timed instead: anything that holds the
editor up for 50 ms or more is kept with its plugin and what it was doing,
`:stalls` lists them, and over 250 ms Greed tells you right away. To see
where time goes when nothing stalls, `:profile` (or `greed.profile.start()`
and `stop()`) counts every run of plugin code and the editor's own work by
plugin and what it did, the most time first.

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

## Events

A plugin reacts to what happens in the editor with `greed.on(event,
handler)`. The handler gets one table describing what happened. Format on
save, the status line, reloading files changed on disk, auto-save and
following an agent around are all built this way.

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
| `option.changed` | An option was set | `name`, `value` |
| `lsp.diagnostics` | A language server reported problems for a buffer | `buffer`; read them with `greed.lsp.diagnostics(buffer)` |
| `view.resized` | A view has room, for a client, for a different number of rows or columns | `view`, `rows`, `cols` |
| `view.scrolled` | A view starts, for a client, at a different line; what the handler changes shows in the same frame, so one view can scroll another along | `view`, `line` |
| `view.closed` | A view was closed, e.g. a plugin's panel | `view`, the closed view's id |
| `pane.opened` | A split opened, from whichever plugin made it | `view`, and `from`, the pane beside it |
| `mouse` | The mouse pressed, released, dragged, moved or scrolled | `kind`, `button` or `dir`, the screen `col` and `row`, the keys held, and what's under it: `view`, `pos` in the buffer, a floating view's `border`, or a `tab` |
| `terminal.output` | A terminal's program printed something | `terminal`; read it with `terminal:screen()` |
| `terminal.exited` | A terminal's program ended | `terminal`, `code` |
| `client.attached` | A client attached to the session, e.g. `greed FILE` | `path` it asked to open, whether it wants a `terminal`, whether it came over `greed ssh` (`remote`) |
| `client.detached` | A terminal or window went; the session goes on without it | `client` |
| `client.paste` | Text was pasted from the system clipboard | `text` |
| `control.request` | A request came on the session socket (`greed ctl`, agents) | `id`, `method`, `params`, `client`, `connection`; answer with `greed.control.reply` |
| `control.closed` | A session socket connection closed, after its last request came; requests from it still waiting have nobody to answer | `connection` |
| `plugin.loaded` | A plugin was loaded or reloaded | `name`, `dir` |
| `plugin.unloaded` | A plugin was unloaded | `name` |
| `editor.started` | Once, when the editor is up with every plugin and your config loaded | nothing |
| `editor.quitting` | Just before the editor quits | nothing |

`space h e` (`:describe-event`) shows any event's fields, and the types
that come with `require("@greed")` have them all. Give the handler's
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
what it printed. `greed.terminal.spawn({ command, rows, cols })` starts one
in a terminal: `terminal.output` events say there's something new to read
with `terminal:screen()` and `terminal:scrollback(from)`, and
`terminal:key("ctrl-c")`, `terminal:write(text)` and `terminal:resize(rows,
cols)` talk back. Styles in a screen are inline names like `=fg:red bold`,
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

### The shell

`require("@shell")` is the [shell](shell.md): `shell.run(sh, line)` runs
a line in a shell as a new block, `shell.of(buffer)` is the shell a buffer
shows, and `shell.wait(block)` waits for a block to finish. A block's
record has what ran and how it ended, its output, and `block.value` when
the output was JSON.

`block.table` is the output read as a table, when it was one: `columns`
(the header's names, in order) and `rows`, each a map from a column's name
to its cell's text. `shell.tables` reads and works on them:
`tables.detect(text, command)`, `tables.from_value(json)`,
`tables.where(tbl, "AGE < 1h")`, `tables.select(tbl, "NAME,AGE")`,
`tables.sort(tbl, "AGE -r")` (each a new table), `tables.number("512Mi")`,
and `tables.draw(tbl)` lines it up as text; `tables.columns(text, true)`,
`tables.csv(text)`, `tables.from_json(text)`, `tables.split(text, ":")`
and `tables.lines(text)` read text that's known to be a table.

`shell.parser(match, parse)` reads the output of the commands `match`
names as tables, ahead of the shell's own look for one: a program's name,
or a pattern for the command line. `parse(text, block)` returns a table,
a list of objects as JSON has them, or nil to leave it to the shell.

```luau
local shell = require("@shell")

-- `terraform state list` prints one address a line.
shell.parser("^terraform state list", function(text)
	local rows = {}
	for address in string.gmatch(text, "[^\n]+") do
		table.insert(rows, { address = address, type = string.match(address, "^[%w_]+") or "" })
	end
	return rows
end)
```

`shell.rows.row_at(sh, block, pos)` is the row under a position in the
buffer, filtered and sorted as the block shows it, for actions on a row:

```luau
local shell = require("@shell")

greed.command({
	name = "pod-logs",
	run = function(ctx)
		local sh = shell.of(ctx.buffer)
		local pos = ctx.view:cursor()
		local block = sh and shell.log.block_at(sh, pos)
		local row = block and block.table and shell.rows.row_at(sh, block, pos)
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
can run programs; `shell.sources.run(name, argv, cwd, env)` runs one the
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
before its folder, after the shell's own (the git branch, the kubernetes
context and the project environment). `provider(ctx)` gets the `shell`,
its `cwd` and the `env` its programs get, and returns `{ text, style,
warning }` or nil for nothing; `warning = true` turns the prompt's `❯` red
too. It runs in the background when a shell opens and after each command,
so it can run a program; the prompt shows the new pieces once every
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

`require("@vcs").branch(dir)` is the branch of the repository a folder is
in, as the status line shows it.

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
`run(tbl, rest)` gets the table and the rest of the stage's words, and
returns a new table (`{ columns, rows }`, each row a map of column to
text), text (which ends the stages, as `to csv` does), or nil and why it
can't.

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
error fails the block with its message. It can wait, as commands can.
Neither can replace the shell's own, and both go when the plugin does.

`shell.kind(spec)` says what the rows of some commands' tables are, so
they're [things to act on](shell.md#rows-you-can-act-on) like any other
(`core.actions`). `spec.match` names the commands as `shell.parser` does.
`spec.capture(block, shell)` runs once as the block finishes and keeps
what the rows can't say themselves, like the context a command ran
against; returning nil says the block isn't this kind's after all.
`spec.row(row, captured, block)` gives `{ kind, label, value }` for a row
(its cells by column), and `spec.called(captured, block)` what one row
and several are called in the block's status ("pod", "pods"). Rows then
take the actions of their kind, whoever added them; `ls -l` rows are
`file` things, so every file action works on them.

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

`shell.action_command(kind, name, command, opts)` adds an action that runs
a command as a block in the shell, so what it does is there to read and
run again. `command` is a template whose `{field}`s are the thing's
value's fields, quoted, or a function from the value to the line.
`opts.doc` says what it does, `opts.danger` makes it ask first (saying
when the value's `context` is a production one), and `opts.default`
makes it what `enter` on such a row does.

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
		return { kind = "service", label = unit, value = { unit = unit } }
	end,
	called = function()
		return "unit", "units"
	end,
})
shell.action_command("service", "status", "systemctl status {unit}", { doc = "How it's doing", default = true })
shell.action_command("service", "restart", "sudo systemctl restart {unit}", { doc = "Restart it", danger = true })
```

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

Each request runs on a thread of its own and both wait like `greed.sleep`,
so they work in commands and event handlers and never hold up the editor.
A plugin needs `net`, or `net:HOST` for each host it talks to.

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
secrets file, and waits like the rest. A plugin declares each secret it
reads as `secrets:NAME`, and Greed's file APIs refuse to read the secrets file
itself.

## Models

The `models` plugin talks to language models for you. Ask for a role, not a
provider, and the user's config decides which model plays it:

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

`models.ask(role, request)` waits for the whole answer instead. Both wait
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
key. `models.no_key(provider)` is the message every feature shows for a
missing key, naming the variable that sets it and `:models`.

For a model that calls tools, `models.turn(role, request, on_text)` runs
one turn: `request` has the conversation as `said` (each `{ role = "user",
text = ... }`, `{ role = "assistant", text = ..., calls = ... }` or `{ role =
"tool", call = ID, text = ... }`), `tools` (each a `name`, a
`description` and a JSON schema as `input`) and an optional `system`.
`on_text` gets the answer's text as it arrives, and the turn comes back as
its `text`, the `calls` it asks for (`id`, `name`, `input`) and `stop`:
`"done"`, or `"tools"` when it wants them run and their results sent in the
next turn. It works the same with Anthropic and with servers that speak
OpenAI's chat completions. A user's turn can carry `images`, a list of PNG
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

Then `:login acme`, and `:models` says "signed in". `:logout acme` forgets
the tokens, and the provider goes back to its key. The name is used for the
secret the tokens are kept in, so it takes lowercase letters, digits and
dashes. Once a login is added it can't be replaced or changed, and its
tokens stay inside the models plugin: no plugin can read them or send them
elsewhere.

Any plugin can add a provider, so a key or a sign-in goes only where the
user let it: the built-in providers' keys to their own servers, and any
other the first time it would go somewhere new, after Greed asks
("send your acme key to https://api.acme.example? y yes, n no"). The
answer is kept, so each key and address asks once.

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

## Agents

Plugins can offer tools to agents. A tool shows up in Claude Code (through
`greed mcp`) and as `greed ctl NAME` in the shell:

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
| `run` | `run(args, caller)` does the work |

Greed's own agent asks the user before a tool whose `kind` isn't `"read"`
runs, the way it asks before its own edits, unless the tool `reviews`;
MCP clients see the others marked read-only. Set `kind` on every tool
that changes, runs or fetches something, so it isn't run unasked.
`sandboxed = true` marks a tool that does more than read but needs no say
from the user, like checking a plugin in an editor of its own.
`shell_only = true` keeps a tool for `greed ctl` and the programs Greed's
shell runs, like `greed edit`: agents aren't offered it and can't call it.

Agents connected when a plugin loads or unloads hear that their tools
changed, so a tool from a plugin you've just approved can be used in the
same conversation.

`run` gets the arguments as a table, and who called as `caller`, whose
`kind` is `"shell"` for `greed ctl`, `"socket"` for MCP clients like
Claude Code, `"ide"` for Claude Code's IDE connection and `"agent"` for
Greed's own agent. Any plugin can call a tool with any `caller`, so don't
decide trust on `kind`: `agent.from_shell(caller)` says whether the call
came from `greed ctl`, whose user can run anything already.

A string `run` returns goes to the agent as it is, and any other value as
JSON, even a table with a `content` field. To answer with MCP's result
form itself, return `agent.result(content, is_error)`, where `content` is
text or a list of pieces like `{ type = "text", text = "..." }`. An error
goes back as an error, so `error("there's no file " .. path, 0)` tells the
agent what went wrong.

Hand text someone else wrote, like a web page or another agent's report,
back through `agent.untrusted(source, text)`: it's wrapped in markers the
text can't close, after a line telling the model to use it as information
and not to follow instructions in it.

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
printed plugin by plugin.

`t:keys("i")` presses keys and `t:type("hello world")` types text a
character at a time, newlines as `enter`. `t:draw(cols, rows)` and
`t:screen(cols, rows)` give what a client would show, as lines of text,
`t:status()` the status line, `t:floats()` the floats' text and
`t:notices()` the desktop notifications sent; `t:clipboard_image(png)`
sets what `greed.clipboard.image()` gives. `t:wait(ms)` moves the clock
forward for code that sleeps, `t:wait_for(check)` waits for real until
`check()` is true (for a program's output), and `t:tempdir(files)` makes a
folder of files to work on; `t:open(path)` opens one of them as
`greed.open` does, without your plugin needing `fs.read` for it.
`local dir, git = t:repo("git", files)` makes a repository (jj or git)
with the files committed and returns a function that runs git there and
fails the test if it fails; `t:vcs("jj", dir)` gives that function for a
folder you set up yourself.

Tests don't show the message about code that held the editor up, so a
busy machine doesn't change what `t:messages()` returns. Each key a test
presses and each command it runs gets the time limit a key press gets in
the editor, and time spent waiting for programs and background work
doesn't count toward it.

`t` acts as the session's first client. `t:client(name)` adds another, as
if a second terminal attached, seeing what the first one does; it has
`keys`, `run`, `mouse`, `draw`, `screen`, `status`, `marked`, `expect`,
`expect_mode` and `id`, all as that client:

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

The API is fully typed in `runtime/types/greed`. `greed new` sets up a
`.luaurc` so `luau-lsp` in your editor and `luau-analyze --mode=strict`
check your plugin against it.

`greed reference DIR` writes the reference pages this site has, as
Markdown: every loaded plugin with its commands, keys and options, every
option, and the whole API. With your config and plugins loaded, they
describe your own setup.

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

### Keeping a registry of your own

A plugin that lets others add to it, like a list of handlers, does the
same with `greed.plugin.tie(remove)`: called in the function others call,
it runs `remove` when the plugin that called it is unloaded or reloaded,
and returns that plugin's name. Calls from your own plugin aren't tied,
since what they added goes with your plugin anyway. `greed.plugin.caller()`
just says who called. `require("@core").registry` makes the `remove`: `set`
puts a value in a table under a key, `put` adds to a list, and each returns
a function that takes the entry out unless it was replaced since. For an
entry you put in a list yourself, `remover(list, entry)` makes that
function.

```luau
local core = require("@core")

local M = {}
local greeters: { [string]: () -> string } = {}

function M.greeter(name: string, greet: () -> string)
	greed.plugin.tie(core.registry.set(greeters, name, greet))
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
it away. Handy while writing a plugin or your `init.luau`:

```luau
#greed.buffers()  -- space l e here shows how many are open, like  ⇒ 3
```

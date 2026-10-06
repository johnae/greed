# Writing plugins

Everything you use in Greed is a plugin written against the API described
here, so the default plugins in `runtime/plugins` are the best examples:
`core` is the whole editing model, `grep` the project search, `agent` the
MCP tools.

## A plugin

```text
~/.config/greed/plugins/greet/
  plugin.toml        name = "greet", what it may use
  init.luau          runs when the plugin loads
  test/greet.luau    tests, run with `greed test greet`
```

`greed new greet` creates this, with a working test and type checking set up.
`plugin.toml` can list plugins this one uses, like
`requires = ["core", "picker"]`; they load first and are available as
`require("@core")` and `require("@picker")`. Files inside a plugin require
each other with `require("@self/name")` or `require("./name")`.

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
| `proc` | Running programs: `greed.process.run`, `greed.terminal.spawn`, `greed.lsp.server`. A program can do anything you can, so this is full access |
| `fs.read` | Files by path: `greed.fs` reads, `greed.files`, `greed.load`, `greed.open`, `greed.image.load`, `greed.pdf.open` |
| `fs.write` | `greed.fs.write`, and `buffer:save(path)` to a path other than the buffer's own file |
| `clipboard` | Reading what you copied (`greed.clipboard.get`, `history`); setting it needs nothing |
| `net` | The network: `greed.http` to any host, and the Claude Code connection |
| `net:HOST` | `greed.http` to one host, e.g. `net:api.anthropic.com` |
| `secrets:NAME` | `greed.secrets.get("NAME")`, e.g. `secrets:anthropic` for an API key |
| `secrets` | Every secret, and keeping new ones |
| `eval` | `greed.eval`, which runs Luau with every capability |
| `plugins` | Loading, unloading and checking other plugins |

Using something the plugin didn't declare raises an error that says what
to add, e.g. `greet can't run programs: add "proc" to capabilities in its
plugin.toml`. Your `init.luau` and a trusted project's `.greed` folder are
config, not plugins, and can use everything.

A plugin that isn't one of Greed's own and declares capabilities loads once
you've approved them. Until then Greed says it waits, and
`:plugins-approve` shows each waiting plugin with what it asks for; choose
one to approve and load it. Approvals are kept per plugin folder in
`~/.local/state/greed/approved.json`, and a plugin that later asks for more
waits again. Plugins that use nothing beyond the editor load at once, and
installing a plugin an agent wrote approves it, since its review shows the
same list. Plugins can't write the approvals file through Greed.

Capabilities follow the code that uses them. A plugin that requires another
can call what that plugin offers, which works with that plugin's
capabilities, so `requires` is part of what a plugin can do. And they limit
plugins only: an agent that runs commands in a shell of its own isn't
affected.

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

greed.keymap.bind("normal", { ["space g"] = "greet" })
```

Commands get a context: `ctx.buffer` and `ctx.view` where they run,
`ctx.args` from the command line (`:greet world`), `ctx.count` when a count
was typed, and `ctx.char` for keys that type a character. Keymaps are bound
per mode, or per kind of buffer with `{ mode = "normal", kind = "tree" }`.
Bindings made later win, and `greed.keymap.unbind` and `greed.keymap.clear`
take keys away, so a plugin can rebuild a mode from scratch. A mode is a
name, and `greed.mode.set("visual")` makes one. `greed.keymap.inherit(mode,
"normal", { "space", ":" })` lets a new mode use some of normal mode's
keys, which is how a whole editing style is built; see [Editing
styles](editing-styles.md#making-your-own); `greed.keymap.inherit_kinds(mode,
"normal")` gives it the keys plugins bind for panels like the file tree.
`greed.keys.record(name)` and `greed.keys.stop(name)` keep what's typed, for
macros and the like; several recordings can run at once. `greed.keymap.fallback(mode,
command)` runs a command for any single key nothing else takes, and
`greed.keymap.isolate(mode)` keeps keys bound for every mode out of one,
the way a terminal takes every key.

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
	plugin = "jira",
	find = function(view, range)
		local buffer = view:buffer()
		local line = buffer:line_of(range.head)
		local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
		local id = string.match(text, "%u+%-%d+")
		return if id then { { kind = "ticket", label = id, value = id } } else nil
	end,
})

actions.action({
	kind = "ticket",
	name = "open",
	doc = "Open it in the browser",
	plugin = "jira",
	run = function(target)
		require("@terminal").open_link(`https://example.atlassian.net/browse/{target.value}`)
	end,
})
```

An action that is an existing command has a short form:
`actions.command("text", "search", "search-selection", "Search for it",
"core")` (kind, name, command, doc, plugin).

The kinds Greed itself uses are `file`, `folder`, `link`, `symbol`,
`problem`, `change`, `button`, `text` (the selection) and `command`, so a
plugin can add actions to those too. A plugin's finders and actions go
when it's unloaded.

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
local line = buffer:line_of(view:selection().ranges[1].head)
buffer:edit(function(e)
	e:insert(buffer:line_start(line), "-- ")
end)
```

Edits made in one `edit` call are one undo step and are applied together,
so their positions all refer to the text before the edit. Selections move
with the text.

`greed.open(path)` shows a file, `greed.load(path)` opens one without showing
it, `greed.create_buffer(kind, text)` makes a scratch buffer, and
`buffer:find`, `buffer:find_all` and `greed.fs.grep` search with regexes.
A scratch buffer goes once nothing shows it, unless `buffer:set_kept(true)`
keeps it, and `buffer:set_line_numbers(false)` hides its line numbers.

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
end
local before = buffer:text_before(tx.id)
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
edit, find it again.

Each language's queries are in `greed.syntax`: `greed.syntax.query("rust",
"textobjects")` is the one in use, and `greed.syntax.set_query` sets one.
A plugin can also ship them as files in its own `queries/LANGUAGE/` folder
(see [Configuration](using.md#highlighting-and-syntax-queries)), and the
`plugin.loaded` event says when a plugin with some arrives.

Folding uses a language's `folds` query, or indentation without one. To
fold a language another way, give core a provider that returns the first
and last line of the block around a line:
`require("@core").folds.providers.org = function(buffer, line) ... end`.
Notes folds Markdown sections this way. New lines' indent works the same
way, with the `indents` query and `require("@core").indent.providers`,
whose functions get the buffer and the place a line break goes in and
return the new line's indent.

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
shown tab's active pane is where `greed.open` opens files.

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
  line, `"cursor"` when one is inside it, or `"never"`, which notes uses
  outside insert mode. A mark can fold lines away under the first one (`fold`),
  or show lines that aren't in the buffer under its own (`lines`), whole
  or in pieces with styles of their own. A mark's text with an `action`
  (a command name) is a button: clicking it, or `enter` on it in normal
  mode, puts the cursor at the mark and runs the command. `scale = 2`
  (up to 4) makes its text bigger, like a heading: each character takes
  twice the cells across and its row two rows down. The window draws it
  big, and so does kitty; other terminals show it at the normal size.
  `buffer:marks_at(pos)` gives the marks over a place in every namespace.
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
  its pages, `doc.render(page, scale)` draws one as an image id at `scale`
  pixels per point, and `doc.text(page)` gives its text, line by line. All
  three wait, like `greed.sleep`.
- Floats show a buffer over the main view, and panels beside it:
  `greed.float(buffer, { title = "Info", width = "60%" })`,
  `greed.panel(buffer, { side = "right", width = 40 })`.
- Pickers (`require("@picker").pick(title, items, choose, options)`)
  filter a list as you type, with an optional preview, or ask a function
  for items as the query changes. `on_move` hears each item as it becomes
  the current one and `on_cancel` hears `esc`, for trying things out live.
  With `paths = { dirs = true, choose = function(path) ... end }`, typing a
  path lists the folder's contents, and `tab` completes one into the query.
- The theme maps style names to looks, as in
  `greed.theme.set({ ["my-plugin.match"] = { fg = "yellow" } })`. Use your own
  names so users can restyle them. Themes themselves go under those
  entries: `greed.theme.base(entries)` replaces the whole base, which is how
  the theme plugin switches themes.
- The status line is pieces you can add to or take away from with
  `require("@statusline").add` and `.remove`, or replace with `greed.statusline`.
- Features are what a plugin turns on for some buffers beyond their
  language, like notes for Markdown in the notes folder. Name yours with
  `require("@core").features.add("todos", function(buffer) return ... end, "my-plugin")`,
  and the status line shows it after the language (`markdown · todos`).
  `core.features.of(buffer)` lists the ones on.
- Choices in Markdown (`- ( )`, `- (x)`) are read with
  `require("@markdown").choices.list(buffer)`: each group with its question
  (the line above it) and its options, `picked` or not. `choices.on_pick(fn,
  "my-plugin")` hears each pick, after the text has changed. A pick only
  edits text; what it does is up to the plugin listening.

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
instead, for pickers that stay open while you work.) `greed.signal()` lets
one piece of code wait for a value another sends. `greed.animate(ms, step)`
calls `step(t)` once a frame, which is all the flash on copy is.
`greed.fs.watch(path)` makes a "file.changed" event come whenever that file
changes, from anywhere; it's how your config reloads.

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

Heavy work doesn't freeze it either. A command or handler that runs for
more than 15 ms without waiting is paused, the editor handles keys and
draws, and it carries on where it was, so a slow plugin is only slow
itself. (`coroutine.yield()` with nothing does the same on purpose.) Your
own coroutines, like a generator made with `coroutine.wrap`, are never
paused this way. One that works for a whole minute without finishing is
stopped and Greed says so. Code that can't be paused, like a status line
piece or a plugin's top level, is timed instead: anything that holds the
editor up for 50 ms or more is kept with its plugin and what it was doing,
`:stalls` lists them, and over 250 ms Greed tells you right away. To see
where time goes when nothing stalls, `:profile` (or `greed.profile.start()`
and `stop()`) counts every run of plugin code and the editor's own work by
plugin and what it did, the most time first.

Language servers ask things too: `greed.lsp.on_request(method, handler)`
answers a server's request, e.g. `workspace/applyEdit`, with what the
handler returns, and the handler can wait, e.g. on a picker, before it
answers. `greed.lsp.on_notification(method, handler)` hears what servers
tell the editor without asking, like `$/progress`; the handler gets the
parameters and the server's language. The status line's language server
piece is built on it.

## Events and options

`greed.on(event, handler)` runs a handler on `buffer.changed`,
`mode.changed`, `command.run`, `keys.pending`, `lsp.diagnostics`,
`view.closed` (for plugins holding on to a panel), `pane.opened` (a split,
from whichever plugin made it), `option.changed`,
`buffer.opened`, `buffer.saved`, `view.resized` (with the rows and
columns `view:size()` also gives), `view.scrolled` (the line now at the
top; what the handler changes shows in the same frame, so one view can
scroll another along), `mouse` (what the mouse did, the view
and buffer position under it, a floating view's `border`, or a tab) and more. A plugin with buffers of
its own kind can take their mouse events first with
`require("@core").mouse.claim(kind, handler)`. `editor.started` comes once, when
the editor is up with every plugin and config loaded, and `editor.quitting`
just before it quits.
`greed.option.define({ name, doc, default })` adds an option users set with
`greed.option.set` or `:set`.

## Programs and terminals

`greed.process.run(command, opts)` runs a program to the end and returns
what it printed. `greed.terminal.spawn({ command, rows, cols })` starts one
in a terminal: `terminal.output` events say there's something new to read
with `terminal:screen()` and `terminal:scrollback(from)`, and
`terminal:key("ctrl-c")`, `terminal:write(text)` and `terminal:resize(rows,
cols)` talk back. Styles in a screen are inline names like `=fg:red bold`,
which you can use in your own marks too. A terminal ends with the plugin
that started it.

`greed.process.spawn(command, { cwd, env })` starts a program to talk to
over its input and output, like an agent or a server speaking JSON-RPC.
`child.write(text)` sends it input, `child.read()` waits for the next
piece it prints (nil once it exited), `child.close()` closes its input,
and `child.wait()` waits for its exit code. It ends with the plugin that
started it, too.

```luau
greed.spawn(function()
	local child = assert(greed.process.spawn({ "sh", "-c", "read x; echo got $x" }))
	child.write("hello\n")
	greed.echo(child.read()) -- got hello
end)
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
in, and `read()` gives the body piece by piece as it arrives, which is how
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
	local piece = stream.read()
	if piece == nil then
		break
	end
	greed.echo(piece)
end
```

Each request runs on a thread of its own and both wait like `greed.sleep`,
so they work in commands and event handlers and never hold up the editor.
A plugin needs `net`, or `net:HOST` for each host it talks to.

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
	local piece = stream.next()
	if piece == nil then
		break
	end
	greed.echo(stream.text)
end
```

`models.ask(role, request)` waits for the whole answer instead. Both wait
like the rest of the API. The roles that come set up are `fast`,
`reasoning` and `local`; a plugin can ask for any role, and the user maps it
in their config.

For a model that calls tools, `models.turn(role, request, on_text)` runs
one turn: `request` has the conversation as `said` (each `{ role = "user",
text = ... }`, `{ role = "assistant", text = ..., calls = ... }` or `{ role =
"tool", call = ID, text = ... }`), `tools` (each a `name`, a
`description` and a JSON schema as `input`) and an optional `system`.
`on_text` gets the answer's text as it arrives, and the turn comes back as
its `text`, the `calls` it asks for (`id`, `name`, `input`) and `stop`:
`"done"`, or `"tools"` when it wants them run and their results sent in the
next turn. It works the same with Anthropic and with servers that speak
OpenAI's chat completions.

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
| `input` | A JSON Schema for the arguments, like `{ type = "object", properties = { path = { type = "string" } }, required = { "path" } }`; left out, it takes none |
| `group` | The group it's offered with; left out, it's always offered (below) |
| `run` | `run(args, client, caller)` does the work |

`run` gets the arguments as a table. `client` is who called: `"shell"` for
`greed ctl`, whose user can run anything already, `"agent"` for Greed's own
agent, otherwise `"socket"`. A string it returns goes to the agent as it
is, any other value as JSON, and an error goes back as an error, so
`error("there's no file " .. path, 0)` tells the agent what went wrong.

A tool can wait: for a process, a request, or the user. Changes to files
are best proposed, so the user reviews them first and the tool hears what
they decided:

```luau
local agent = require("@agent")

agent.tool({
	name = "add_license",
	description = "Propose adding the license header to a file",
	input = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
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
waits for their answers.

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
default plugins loaded. `t:wait(ms)` moves the clock forward for code that
sleeps, `t:wait_for(check)` waits for real until `check()` is true (for a
program's output), and `t:tempdir(files)` makes a folder of files to work
on.

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
`greed.plugin.unload(name)` removes them. A plugin that runs too long is
stopped, so a mistake in a loop can't hang the editor.

## Trying code

`:lua CODE` runs Luau in a scratch environment whose globals last, and
`:= EXPR` shows what an expression is. In any buffer, `space l e` runs the
selection, or the line the cursor is on, the same way, and shows what it
returned at the end of its last line (or the error); the next edit takes
it away. Handy while writing a plugin or your `init.luau`:

```luau
#greed.buffers()  -- space l e here shows how many are open, like  ⇒ 3
```

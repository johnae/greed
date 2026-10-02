# Writing plugins

Everything you use in Kern is a plugin written against the API described
here, so the default plugins in `runtime/plugins` are the best examples:
`core` is the whole editing model, `grep` the project search, `agent` the
MCP tools.

## A plugin

```text
~/.config/kern/plugins/greet/
  plugin.toml        name = "greet"
  init.luau          runs when the plugin loads
  test/greet.luau    tests, run with `kern test greet`
```

`kern new greet` creates this, with a working test and type checking set up.
`plugin.toml` can list plugins this one uses, like
`requires = ["core", "picker"]`; they load first and are available as
`require("@core")` and `require("@picker")`. Files inside a plugin require
each other with `require("@self/name")` or `require("./name")`.

Plugins are Luau, a typed dialect of Lua. If you know Lua, the differences
you'll meet are types (`local n: number = 1`), `if a then b else c` as an
expression, backtick strings with `{interpolation}`, `+=`, and `for k, v in
t do` without `pairs`.

## Commands and keys

```luau
local kern = require("@kern")

kern.command({
	name = "greet",
	doc = "Say hello",
	args = { { name = "who", doc = "Who to greet" } },
	run = function(ctx)
		kern.echo(`hello {ctx.args[1] or "there"}`)
	end,
})

kern.keymap.bind("normal", { ["space g"] = "greet" })
```

Commands get a context: `ctx.buffer` and `ctx.view` where they run,
`ctx.args` from the command line (`:greet world`), `ctx.count` when a count
was typed, and `ctx.char` for keys that type a character. Keymaps are bound
per mode, or per kind of buffer with `{ mode = "normal", kind = "tree" }`.
Bindings made later win, and `kern.keymap.unbind` and `kern.keymap.clear`
take keys away, so a plugin can rebuild a mode from scratch. A mode is a
name, and `kern.mode.set("visual")` makes one. `kern.keymap.inherit(mode,
"normal", { "space", ":" })` lets a new mode use some of normal mode's
keys, which is how a whole editing style is built; see [Editing
styles](editing-styles.md#making-your-own). `kern.keymap.fallback(mode,
command)` runs a command for any single key nothing else takes, and
`kern.keymap.isolate(mode)` keeps keys bound for every mode out of one,
the way a terminal takes every key.

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

`kern.open(path)` shows a file, `kern.load(path)` opens one without showing
it, `kern.create_buffer(kind, text)` makes a scratch buffer, and
`buffer:find`, `buffer:find_all` and `kern.fs.grep` search with regexes.
A scratch buffer goes once nothing shows it, unless `buffer:set_kept(true)`
keeps it, and `buffer:set_line_numbers(false)` hides its line numbers.

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

Each language's queries are in `kern.syntax`: `kern.syntax.query("rust",
"textobjects")` is the one in use, and `kern.syntax.set_query` sets one.
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

The editor can have several projects open. `kern.project.current()` is
the one shown, with its `root`; `kern.project.open`, `switch` and `close`
manage them, and `buffer:project()` says which one a buffer belongs to.
Panels belong to the project they were opened in, so a plugin that keeps
one (like a results panel) should keep one per project.

Each project has tabs (`kern.tab.list`, `new`, `switch`, `close`,
`rename`), and each tab has panes laid out side by side and one above
another. `view:split("right", buffer)` opens a pane, `view:neighbor("left")`
finds the one beside it, `view:resize("down", 2)` moves its edge, and
`view:close()` closes it. `kern.view()` is the focused view, and the
shown tab's active pane is where `kern.open` opens files.

`kern.tab.layout()` gives a tab's arrangement as a tree, and
`kern.tab.set_layout(tree)` arranges its panes another way:

```luau
local a, b, c = table.unpack(kern.tab.current().panes)
-- a across the top, a quarter high; b and c side by side under it
kern.tab.set_layout({
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
  labels). It can also hide text (`conceal`, like a link's brackets, shown
  again on the cursor's line), fold lines away under the first one (`fold`),
  or show lines that aren't in the buffer under its own (`lines`), whole
  or in pieces with styles of their own. A mark's text with an `action`
  (a command name) is a button: clicking it, or `enter` on it in normal
  mode, puts the cursor at the mark and runs the command.
  `buffer:marks_at(pos)` gives the marks over a place in every namespace.
- Multibuffers show excerpts of many files in one buffer, edited in place:
  `require("@multibuffer").open({ { path = path, from = 9, to = 12 } },
  { summary = "3 places" })` gives a buffer to show in a panel or float,
  or in the shared results panel with `.show(buffer, "Title")`. An excerpt
  can carry `marks` to style ranges in it and a `note` shown after its
  file's name. Edits in it change the files as you type, and changes to
  the files show in it. Search results, references and the problems list
  use one.
- Images: `kern.image.load(path)` reads a PNG, JPEG or GIF and gives an id,
  and a mark with `image = { id = id, cols = 20, rows = 8 }` draws it over
  that many cells from its start. `kern.image.cells(id)` says how many
  cells it covers at its own size.
- Floats show a buffer over the main view, and panels beside it:
  `kern.float(buffer, { title = "Info", width = "60%" })`,
  `kern.panel(buffer, { side = "right", width = 40 })`.
- Pickers (`require("@picker").pick(title, items, choose, options)`)
  filter a list as you type, with an optional preview, or ask a function
  for items as the query changes. `on_move` hears each item as it becomes
  the current one and `on_cancel` hears `esc`, for trying things out live.
- The theme maps style names to looks, as in
  `kern.theme.set({ ["my-plugin.match"] = { fg = "yellow" } })`. Use your own
  names so users can restyle them. Themes themselves go under those
  entries: `kern.theme.base(entries)` replaces the whole base, which is how
  the theme plugin switches themes.
- The status line is built by a function you can replace with
  `kern.statusline`.

## Waiting

Commands and event handlers can wait without freezing the editor:
`kern.sleep(ms)`, `kern.next_key()`, `kern.lsp.request(...)` and
`kern.fs.grep(...)` pause the command until the result is there, and
`kern.signal()` lets one piece of code wait for a value another sends.
`kern.animate(ms, step)` calls `step(t)` once a frame, which is all the
flash on copy is.

Language servers ask things too: `kern.lsp.on_request(method, handler)`
answers a server's request, e.g. `workspace/applyEdit`, with what the
handler returns.

## Events and options

`kern.on(event, handler)` runs a handler on `buffer.changed`,
`mode.changed`, `command.run`, `keys.pending`, `lsp.diagnostics`,
`view.closed` (for plugins holding on to a panel), `pane.opened` (a split,
from whichever plugin made it), `option.changed`,
`buffer.opened`, `buffer.saved`, `view.resized` (with the rows and
columns `view:size()` also gives), `view.scrolled` (the line now at the
top; what the handler changes shows in the same frame, so one view can
scroll another along), `mouse` (what the mouse did, the view
and buffer position under it, or a tab) and more. A plugin with buffers of
its own kind can take their mouse events first with
`require("@core").mouse.claim(kind, handler)`. `editor.started` comes once, when
the editor is up with every plugin and config loaded, and `editor.quitting`
just before it quits.
`kern.option.define({ name, doc, default })` adds an option users set with
`kern.option.set` or `:set`.

## Programs and terminals

`kern.process.run(command, opts)` runs a program to the end and returns
what it printed. `kern.terminal.spawn({ command, rows, cols })` starts one
in a terminal: `terminal.output` events say there's something new to read
with `terminal:screen()` and `terminal:scrollback(from)`, and
`terminal:key("ctrl-c")`, `terminal:write(text)` and `terminal:resize(rows,
cols)` talk back. Styles in a screen are inline names like `=fg:red bold`,
which you can use in your own marks too. A terminal ends with the plugin
that started it.

## Agents

Plugins can offer tools to agents. A tool shows up in Claude Code (through
`kern mcp`) and as `kern ctl NAME` in the shell:

```luau
require("@agent").tool({
	name = "word_count",
	description = "How many words the current file has",
	run = function()
		local _, words = string.gsub(require("@kern").view():buffer():text(), "%S+", "")
		return tostring(words)
	end,
})
```

## Tests

```luau
local test = require("@kern/test")

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

`kern test DIR` runs a plugin's tests, each in a fresh editor with the
default plugins loaded. `t:wait(ms)` moves the clock forward for code that
sleeps, `t:wait_for(check)` waits for real until `check()` is true (for a
program's output), and `t:tempdir(files)` makes a folder of files to work
on.

## Types

The API is fully typed in `runtime/types/kern`. `kern new` sets up a
`.luaurc` so `luau-lsp` in your editor and `luau-analyze --mode=strict`
check your plugin against it.

## Loading and reloading

Kern loads the default plugins, then yours, then `init.luau`. Each plugin
runs in its own environment and owns what it registers: reloading a plugin
replaces its commands, keys, options, handlers and theme entries, and
`kern.plugin.unload(name)` removes them. A plugin that runs too long is
stopped, so a mistake in a loop can't hang the editor.

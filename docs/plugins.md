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
styles](editing-styles.md#making-your-own).

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

The editor can have several projects open. `kern.project.current()` is
the one shown, with its `root`; `kern.project.open`, `switch` and `close`
manage them, and `buffer:project()` says which one a buffer belongs to.
Panels belong to the project they were opened in, so a plugin that keeps
one (like a results panel) should keep one per project.

## Showing things

- Decorations style text without changing it, and move with edits:
  `buffer:decorate("my-plugin", { { from = 0, to = 5, style = "diagnostic.error" } })`.
  A mark can style whole lines, add virtual text inside or after a line,
  put a sign in the gutter, or draw text over the buffer's (like jump
  labels). It can also hide text (`conceal`, like a link's brackets, shown
  again on the cursor's line), fold lines away under the first one (`fold`),
  or show lines that aren't in the buffer under its own (`lines`).
- Floats show a buffer over the main view, and panels beside it:
  `kern.float(buffer, { title = "Info", width = "60%" })`,
  `kern.panel(buffer, { side = "right", width = 40 })`.
- Pickers (`require("@picker").pick(title, items, choose, options)`)
  filter a list as you type, with an optional preview, or ask a function
  for items as the query changes.
- The theme maps style names to looks, as in
  `kern.theme.set({ ["my-plugin.match"] = { fg = "yellow" } })`. Use your own
  names so users can restyle them.
- The status line is built by a function you can replace with
  `kern.statusline`.

## Waiting

Commands and event handlers can wait without freezing the editor:
`kern.sleep(ms)`, `kern.next_key()`, `kern.lsp.request(...)` and
`kern.fs.grep(...)` pause the command until the result is there, and
`kern.signal()` lets one piece of code wait for a value another sends.
`kern.animate(ms, step)` calls `step(t)` once a frame, which is all the
flash on copy is.

## Events and options

`kern.on(event, handler)` runs a handler on `buffer.changed`,
`mode.changed`, `command.run`, `keys.pending`, `lsp.diagnostics`,
`view.closed` (for plugins holding on to a panel), `option.changed`,
`buffer.opened`, `buffer.saved` and more. `editor.started` comes once, when
the editor is up with every plugin and config loaded, and `editor.quitting`
just before it quits.
`kern.option.define({ name, doc, default })` adds an option users set with
`kern.option.set` or `:set`.

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
sleeps, and `t:tempdir(files)` makes a folder of files to work on.

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

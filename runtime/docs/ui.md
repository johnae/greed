# Building interfaces

`core.ui` draws an interface into a buffer as text and marks. A plugin
describes what to show for its state, and `core.ui` lays it out for the
view's width and changes only the lines that changed. The result is text,
so search, copy, `y`, an agent's `read` and the usual keys work on it, in
the terminal and in the window. The picker, completion, the command line,
the undo tree and the agent's chat are built with it.

## A first view

A small inbox: a search field, a toggle, and a list of messages that
opens one when you press it. `:inbox` shows it in a float.

```luau
local greed = require("@greed")
local core = require("@core")
local ui = core.ui

type Message = { id: number, from: string, subject: string, read: boolean }

local messages: { Message } = {
	{ id = 1, from = "Ada", subject = "Lunch on Friday?", read = false },
	{ id = 2, from = "CI", subject = "main is green again", read = true },
	{ id = 3, from = "Grace", subject = "The release notes", read = false },
}

local function render(view: core.UiView, state): core.UiNode
	local shown = {}
	for _, m in messages do
		if state.unread_only and m.read then
			continue
		end
		if string.find(string.lower(m.subject), string.lower(state.query), 1, true) then
			table.insert(shown, m)
		end
	end
	return ui.column({
		ui.row({
			ui.field("Search", state.query, function(text)
				view:set({ query = text })
			end),
			ui.toggle("Unread only", state.unread_only, function(on)
				view:set({ unread_only = on })
			end),
		}),
		ui.gap(),
		ui.list(shown, function(m: Message)
			return {
				ui.span(if m.read then "  " else "● ", "ui.menu.badge"),
				ui.span(string.format("%-8s", m.from), "ui.menu.doc"),
				ui.span(m.subject),
			}
		end, {
			open = function(m: Message)
				m.read = true
				view:redraw()
				greed.echo(`{m.from}: {m.subject}`)
			end,
		}),
	})
end

greed.command({
	name = "inbox",
	doc = "Show the inbox",
	run = function()
		local buffer = greed.create_buffer("inbox", "", { readonly = true })
		greed.float(buffer, { title = "Inbox", width = 60, height = 12 })
		local view: core.UiView
		view = ui.mount(buffer, function(state)
			return render(view, state)
		end, { query = "", unread_only = false }, {
			key = function(m: Message): string
				return tostring(m.id)
			end,
			draw = false,
		})
		view:redraw()
	end,
})
```

It draws as:

```text
Search: [      ]                         ☐ Unread only

● Ada     Lunch on Friday?
  CI      main is green again
● Grace   The release notes
```

`ui.mount(buffer, render, state, opts)` ties a render function and its
state to a buffer and gives back the view. `render` is called with the
state whenever it changes or the buffer's views change width, and returns
nodes. `draw = false` holds the first drawing until `view:redraw()`, so
the widgets' functions can use `view` once it's set.

## State and drawing again

- `view:set(patch)` merges `patch` into the state and draws again.
- `view:redraw()` draws again from the state as it is, after something
  outside it changed, like a message marked read above.
- `view:soon(patch)` draws once for a burst of changes, as tokens of an
  answer streaming in.
- `view:unmount()` stops drawing; the buffer keeps what it showed last.

Only lines whose text or marks changed are written, so a cursor elsewhere
stays put. While a view is resized, as when you drag its pane's edge, it's
drawn at once, then at most every 100 ms, then once more where the drag
ends.

## The parts

| Node | What it draws |
|---|---|
| `ui.text(text, style?)` | Text, wrapped to the width |
| `ui.span(text, style?)` | A piece of a line, for `line`, `list` and `grid` |
| `ui.line(spans)` | One line of spans |
| `ui.column(nodes)` | Nodes one under another |
| `ui.row(nodes)` | Nodes side by side |
| `ui.gap()` | An empty line |
| `ui.box(title, node, style?)` | A node in a border with a title |
| `ui.button(label, on_press)` | A button |
| `ui.field(label, value, on_change)` | A value shown in a box; pressing asks for a new one |
| `ui.toggle(label, on, on_change)` | A check box |
| `ui.list(items, spans, { open, current })` | An item a line; pressing one calls `open` |
| `ui.grid(rows, { gap })` | Columns lined up without borders |
| `ui.table({ columns, rows, on_open })` | A table with borders |
| `ui.keyed(key, version, build)` | A part drawn again only when its version changes |

A span can carry more than text: `press` makes it a widget of its own,
`value` is what it stands for (below), `tag` names it for
`view:spots(tag)`, `line` styles its whole line, and `marks` are marks of
its own counted from its start. `ui.matched(text, positions)` gives the
spans of a fuzzy match with the matched letters picked out, as menus show
them.

## Keys and focus

`tab` and `shift-tab` move between widgets, and `enter`, `space` or a
click presses the one under the cursor. The cursor is the focus, so each
client looking at the view has its own. The other keys are the buffer's
as usual: `/` searches the view, `y` copies from it. With `keys = false`
in the options, `tab` and `shift-tab` are left to your plugin.

## Values under the cursor

A span's `value` belongs to its line, so the plugin can ask what the
cursor is on without tracking line numbers. `ui.list` and `ui.grid` set
each line's value to its item or row.

- `view:value_at(pos)` gives the value of the span at `pos`, else of its
  line. On a line of several things, like a strip of tabs, it gives the
  one under the cursor.
- `view:value_on(line)` gives a line's value, `view:values()` all of
  them, and `view:each(f)` calls `f` with each line that has one.
- `view:line_of(f)` finds the first line whose value `f` says yes to, to
  put the cursor there.

With `key` in the options, naming each value (`m.id` above), a cursor
stays on its item as the lines change places, as when the list is filtered
or sorted again. `ui.list(items, spans, { current = n })` marks row `n` as
a menu's selected row, for a list whose cursor is somewhere else.

## Long views that change at one end

A chat or a log grows at the bottom while the rest stays. Wrap each part
in `ui.keyed(key, version, build)`: a part whose key and version are the
same as last time isn't built or laid out again, so a streamed token
costs what its message does rather than the whole transcript.

```luau
local parts = {}
for _, m in messages do
	table.insert(parts, ui.keyed(m.id, #m.text, function()
		return ui.text(m.text)
	end))
end
return ui.column(parts)
```

A keyed part is laid out again for a new width, unless
`ui.keyed(key, version, build, { any_width = true })` says its lines don't
depend on it (the view wraps them, as it does a message's text).

## A view with an input

With `input = true`, the view is drawn at the top of the buffer and what's
written under it belongs to the user, like a chat's box. The view's part
is read-only, `view:input()` reads what's written and `view:input_start()`
says where it begins. With `above = true` too, the first line is the input
and the view is drawn under it, as the picker's list is under its query.

## Testing it

Plugin tests drive a view with keys, as a user would:

```luau
local test = require("@greed/test")

test("the inbox filters and opens messages", function(t)
	t:buffer("|x")
	t:run("inbox")
	t:keys("tab tab enter") -- the field, then the toggle, pressed
	local shown = t:floats()[1]
	assert(not string.find(shown, "main is green", 1, true), shown)
	t:keys("tab enter") -- the first message
	local said = t:messages()
	assert(said[#said] == "Ada: Lunch on Friday?", said[#said])
end)
```

## More

The rest of the options (`ns` and `width` for marks and layout, `after`
to draw with each frame, `ui.pieces` to draw nodes as a mark's lines) are
in [Writing plugins](plugins.md) and the types of `core.ui` in the
plugin reference under `core` ([Plugins](reference/plugins.md)).

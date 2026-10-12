-- A small toolkit for plugins' interfaces: a view is a function from its
-- state to a tree of widgets, drawn as a buffer's text and marks, so
-- search, copy, an agent's `read` and every editor key work on it as on
-- any text, in the terminal and the window alike.
--
--     local ui = require("@core").ui
--     local view = ui.mount(buffer, function(state)
--         return ui.column({
--             ui.line({ ui.span("Inbox", "markdown.heading.2") }),
--             ui.field("search", state.query, function(text) view:set({ query = text }) end),
--             ui.table({ columns = { "from", "subject" }, rows = state.mail, on_open = read }),
--         })
--     end, { query = "", mail = {} })
--
-- A node lays itself out for a width as lines of spans. A span that does
-- something when pressed (a button, a field, a row) is a widget: `enter`,
-- `space` or a click presses it, and `tab` and `shift-tab` go from one to
-- the next. The cursor is the focus, so each client has its own. Redrawing
-- changes only the lines that changed, so cursors stay where they were.

local greed = require("@greed")
local text_helpers = require("./text")
local prompt = require("./prompt")
local formula = require("./formula")

local width, clip = text_helpers.width, text_helpers.clip

local M = {}

--- Text in a style; `press`, if given, makes it a widget pressing calls.
export type Span = { text: string, style: string?, press: (() -> ())? }

--- A line of spans.
export type Line = { Span }

--- A part of an interface: its lines, laid out for a width in cells.
export type Node = { lay: (cells: number) -> { Line } }

--- A mounted view: its buffer, its state, and what draws it.
export type View = {
	buffer: greed.Buffer,
	state: { [string]: any },
	--- Merges `patch` into the state and draws the view again.
	set: (self: View, patch: { [string]: any }) -> (),
	--- Draws the view again, as its state says now.
	redraw: (self: View) -> (),
	--- Stops drawing it; the buffer stays as it was last drawn.
	unmount: (self: View) -> (),
}

--- A span of `text`, in `style`.
function M.span(text: string, style: string?): Span
	return { text = text, style = style }
end

--- One line of `spans`, cut where it's wider than the view.
function M.line(spans: { Span }): Node
	return {
		lay = function(cells: number): { Line }
			local out: Line = {}
			local room = cells
			for _, span in spans do
				if room <= 0 then
					break
				end
				local shown = clip(span.text, room)
				room -= width(shown)
				table.insert(out, { text = shown, style = span.style, press = span.press })
			end
			return { out }
		end,
	}
end

--- `text` in `style`, wrapped at spaces to the view's width; its own
--- line breaks start new lines.
function M.text(text: string, style: string?): Node
	return {
		lay = function(cells: number): { Line }
			local out: { Line } = {}
			for _, paragraph in string.split(text, "\n") do
				local line = ""
				for word in string.gmatch(paragraph, "%S+") do
					local joined = if line == "" then word else `{line} {word}`
					if width(joined) > cells and line ~= "" then
						table.insert(out, { { text = line, style = style } })
						line = word
					else
						line = joined
					end
				end
				table.insert(out, { { text = clip(line, cells), style = style } })
			end
			return out
		end,
	}
end

--- An empty line.
function M.gap(): Node
	return M.line({})
end

--- `children` one under another.
function M.column(children: { Node }): Node
	return {
		lay = function(cells: number): { Line }
			local out: { Line } = {}
			for _, child in children do
				for _, line in child.lay(cells) do
					table.insert(out, line)
				end
			end
			return out
		end,
	}
end

-- How wide `line` is in cells.
local function line_width(line: Line): number
	local n = 0
	for _, span in line do
		n += width(span.text)
	end
	return n
end

--- `children` side by side, `gap` cells apart, sharing the width evenly
--- unless `widths` says how wide each is (the last taking what's left).
function M.row(children: { Node }, opts: { gap: number?, widths: { number }? }?): Node
	local gap = (opts and opts.gap) or 2
	local fixed: { number } = (opts and opts.widths) or {}
	return {
		lay = function(cells: number): { Line }
			local n = #children
			local each = math.max((cells - gap * (n - 1)) // math.max(n, 1), 1)
			local widths: { number } = {}
			local used = 0
			for i = 1, n do
				local given = fixed[i]
				widths[i] = if given and i < n
					then given
					elseif i == n then math.max(cells - used - gap * (n - 1), 1)
					else each
				used += widths[i]
			end
			local laid: { { Line } } = {}
			local height = 0
			for i, child in children do
				laid[i] = child.lay(widths[i])
				height = math.max(height, #laid[i])
			end
			local out: { Line } = {}
			for r = 1, height do
				local line: Line = {}
				for i = 1, n do
					local part: Line = laid[i][r] or {}
					for _, span in part do
						table.insert(line, span)
					end
					if i < n then
						local pad = widths[i] - line_width(part) + gap
						table.insert(line, { text = string.rep(" ", math.max(pad, 0)) })
					end
				end
				table.insert(out, line)
			end
			return out
		end,
	}
end

--- `child` in a box with `title` on its top border, drawn in `style`.
function M.box(title: string, child: Node, style: string?): Node
	local border = style or "markdown.table"
	return {
		lay = function(cells: number): { Line }
			local inner = math.max(cells - 4, 1)
			local head = if title == "" then "" else ` {title} `
			local rest = string.rep("─", math.max(inner + 1 - width(head), 0))
			local top = "╭─" .. head .. rest .. "╮"
			local out: { Line } = { { { text = top, style = border } } }
			for _, line in child.lay(inner) do
				local row: Line = { { text = "│ ", style = border } }
				for _, span in line do
					table.insert(row, span)
				end
				table.insert(row, { text = string.rep(" ", math.max(inner - line_width(line), 0)) })
				table.insert(row, { text = " │", style = border })
				table.insert(out, row)
			end
			table.insert(
				out,
				{ { text = "╰" .. string.rep("─", inner + 2) .. "╯", style = border } }
			)
			return out
		end,
	}
end

--- A button: `[ label ]`, calling `on_press` when pressed.
function M.button(label: string, on_press: () -> ()): Node
	return M.line({ { text = `[ {label} ]`, style = "markdown.field", press = on_press } })
end

--- A field: `label: [ value ]`; pressing it asks for a new value, which
--- goes to `on_change`.
function M.field(label: string, value: string, on_change: (value: string) -> ()): Node
	local shown = if value == "" then "    " else value
	return M.line({
		{ text = `{label}: ` },
		{
			text = `[ {shown} ]`,
			style = "markdown.field",
			press = function()
				greed.spawn(function()
					local typed = prompt.ask(label, value)
					if typed ~= nil then
						on_change(typed)
					end
				end)
			end,
		},
	})
end

--- A box to tick: `☑ label` or `☐ label`, pressing it giving `on_change`
--- the other.
function M.toggle(label: string, on: boolean, on_change: (on: boolean) -> ()): Node
	return M.line({
		{
			text = `{if on then "☑" else "☐"} {label}`,
			style = if on then "markdown.chosen" else "markdown.choice",
			press = function()
				on_change(not on)
			end,
		},
	})
end

--- A border across columns `widths` wide: `left`, `middle` between
--- columns and `right`, e.g. "├", "┼", "┤".
function M.border(widths: { number }, left: string, middle: string, right: string): string
	local parts: { string } = {}
	for _, w in widths do
		table.insert(parts, string.rep("─", w + 2))
	end
	return left .. table.concat(parts, middle) .. right
end

-- A table's column, as it's drawn.
type TableColumn = { name: string, title: string, right: boolean }

--- A table: `columns` (names, or `{ name, title?, right? }`) over `rows`,
--- each a row of values by column name, lined up in boxes; pressing a row
--- calls `on_open` with it. A column holding only numbers lines up on the
--- right. No column is wider than `widest` cells (40).
function M.table(spec: {
	columns: { any },
	rows: { { [string]: any } },
	on_open: ((row: { [string]: any }, index: number) -> ())?,
	widest: number?,
}): Node
	local columns: { TableColumn } = {}
	for _, given in spec.columns do
		local c: any = if type(given) == "string" then { name = given } else given
		local right = c.right
		if right == nil then
			right = #spec.rows > 0
			for _, row in spec.rows do
				local v = row[c.name]
				right = right and (v == nil or type(v) == "number")
			end
		end
		table.insert(columns, { name = c.name, title = c.title or c.name, right = right })
	end
	local show = formula.show
	return {
		lay = function(cells: number): { Line }
			local widest = spec.widest or 40
			local widths: { number } = {}
			for i, c in columns do
				local w = width(c.title)
				for _, row in spec.rows do
					w = math.max(w, width(show(row[c.name])))
				end
				widths[i] = math.clamp(w, 1, widest)
			end
			-- Narrower until it fits: the widest columns give up room first.
			local function total(): number
				local n = 1
				for _, w in widths do
					n += w + 3
				end
				return n
			end
			while total() > cells do
				local most, at = 0, 0
				for i, w in widths do
					if w > most then
						most, at = w, i
					end
				end
				if most <= 3 then
					break
				end
				widths[at] -= 1
			end
			local border = "markdown.table"
			local function rule(left: string, middle: string, right: string): Line
				return { { text = M.border(widths, left, middle, right), style = border } }
			end
			local function cells_of(values: { string }, style: string, press: (() -> ())?): Line
				local line: Line = { { text = "│ ", style = border } }
				for i, value in values do
					local shown = clip(value, widths[i])
					local room = widths[i] - width(shown)
					local padded = if columns[i].right and style ~= "markdown.table.header"
						then string.rep(" ", room) .. shown
						else shown .. string.rep(" ", room)
					table.insert(line, { text = padded, style = style, press = press })
					table.insert(
						line,
						{ text = if i < #values then " │ " else " │", style = border }
					)
				end
				return line
			end
			local titles: { string } = {}
			for _, c in columns do
				table.insert(titles, c.title)
			end
			local out: { Line } = {
				rule("┌", "┬", "┐"),
				cells_of(titles, "markdown.table.header"),
				rule("├", "┼", "┤"),
			}
			local open = spec.on_open
			for index, row in spec.rows do
				local values: { string } = {}
				for _, c in columns do
					table.insert(values, show(row[c.name]))
				end
				local press = if open
					then function()
						open(row, index)
					end
					else nil
				table.insert(out, cells_of(values, "markdown.table.cell", press))
			end
			table.insert(out, rule("└", "┴", "┘"))
			return out
		end,
	}
end

--- `items` one a line, each drawn as `spans(item)`; pressing a line calls
--- `on_open` with its item.
function M.list<T>(items: { T }, spans: (item: T) -> { Span }, on_open: ((item: T) -> ())?): Node
	local lines: { Node } = {}
	for _, item in items do
		local parts = spans(item)
		if on_open then
			for _, span in parts do
				span.press = function()
					on_open(item)
				end
			end
		end
		table.insert(lines, M.line(parts))
	end
	return M.column(lines)
end

--- `node` as text and marks for `cells` wide: each pressable span a mark
--- whose action is `ui-press`, with its index in `presses`.
function M.draw(node: Node, cells: number): (string, { greed.Mark }, { () -> () })
	local texts: { string } = {}
	local marks: { greed.Mark } = {}
	local presses: { () -> () } = {}
	local at = 0
	for _, line in node.lay(cells) do
		local parts: { string } = {}
		for _, span in line do
			local from = at
			at += #span.text
			table.insert(parts, span.text)
			if span.press then
				table.insert(presses, span.press)
				table.insert(marks, {
					from = from,
					to = at,
					style = span.style or "",
					action = "ui-press",
					data = { ui = #presses },
				})
			elseif span.style and span.text ~= "" then
				table.insert(marks, { from = from, to = at, style = span.style })
			end
		end
		table.insert(texts, table.concat(parts))
		at += 1
	end
	return table.concat(texts, "\n"), marks, presses
end

--- `lines` (a node laid out) as lines a mark shows under a line (a mark's
--- `lines`): drawn, not text, so their widgets can't be pressed.
function M.pieces(lines: { Line }): { greed.MarkLine }
	local out: { greed.MarkLine } = {}
	for _, line in lines do
		local pieces: { { text: string, style: string?, action: string? } } = {}
		for _, span in line do
			table.insert(pieces, { text = span.text, style = span.style })
		end
		table.insert(out, pieces)
	end
	return out
end

-- What's mounted, by buffer id: its view and what each widget does.
local mounted: { [number]: { view: View, presses: { () -> () } } } = {}

--- How wide `buffer` is shown: the narrowest view of it, else 80 cells.
function M.width(buffer: greed.Buffer): number
	local least: number? = nil
	for _, view in buffer:views() do
		local _, cols = view:size()
		if cols then
			least = math.min(least or cols, cols)
		end
	end
	return least or 80
end

-- Replaces the lines of `buffer` that differ from `text`, as one edit.
local function replace_changed(buffer: greed.Buffer, text: string)
	local old = buffer:slice(0, buffer:len())
	if old == text then
		return
	end
	local a, b = string.split(old, "\n"), string.split(text, "\n")
	local first = 1
	while first <= #a and first <= #b and a[first] == b[first] do
		first += 1
	end
	local last_a, last_b = #a, #b
	while last_a >= first and last_b >= first and a[last_a] == b[last_b] do
		last_a -= 1
		last_b -= 1
	end
	-- Lines `first` to `last_a` of the old text become `first` to `last_b`.
	local from = if first <= #a then buffer:line_start(first - 1) else buffer:len()
	local to = if last_a >= first then buffer:line_end(last_a - 1) else from
	local lines = table.move(b, first, last_b, 1, {})
	local new = table.concat(lines, "\n")
	if last_a < first and last_b >= first then
		-- Only lines added: they join with a line break on the right side.
		new = if first <= #a then new .. "\n" else "\n" .. new
	elseif last_b < first and last_a >= first then
		-- Only lines taken away, with the line break before or after them.
		if first > 1 then
			from = buffer:line_end(first - 2)
		elseif last_a < #a then
			to = buffer:line_start(last_a)
		end
	end
	buffer:edit(function(e)
		e:replace(from, to, new)
	end, { undo = false })
end

--- Draws `render(state)` into `buffer` for the width of its views, and
--- again whenever the state is set or a view of it is resized. Gives the
--- view, whose `set` merges into its state.
function M.mount(
	buffer: greed.Buffer,
	render: (state: { [string]: any }) -> Node,
	state: { [string]: any }?
): View
	local view: View = {
		buffer = buffer,
		state = state or {},
		set = function(self: View, patch: { [string]: any })
			for k, v in patch do
				self.state[k] = v
			end
			self:redraw()
		end,
		redraw = function(self: View)
			local entry = mounted[buffer:id()]
			if entry == nil or entry.view ~= self or not buffer:valid() then
				return
			end
			local text, marks, presses = M.draw(render(self.state), M.width(buffer))
			entry.presses = presses
			replace_changed(buffer, text)
			buffer:decorate("ui", marks)
		end,
		unmount = function(self: View)
			local entry = mounted[buffer:id()]
			if entry and entry.view == self then
				mounted[buffer:id()] = nil
			end
		end,
	}
	mounted[buffer:id()] = { view = view, presses = {} }
	buffer:set_keys({ tab = "ui-next", ["shift-tab"] = "ui-prev" })
	greed.plugin.tie(function()
		view:unmount()
	end)
	view:redraw()
	-- The first drawing went in at the cursor, which it pushed to the end.
	for _, shown in buffer:views() do
		shown:set_selection({ ranges = { { anchor = 0, head = 0 } }, primary = 1 })
	end
	return view
end

--- The view mounted in `buffer`, if one is.
function M.of(buffer: greed.Buffer): View?
	local entry = mounted[buffer:id()]
	return if entry then entry.view else nil
end

-- The widgets of the view in `buffer`, by where they start.
local function widgets(buffer: greed.Buffer): { number }
	local starts: { number } = {}
	for _, mark in buffer:decorations("ui") do
		if mark.action == "ui-press" then
			table.insert(starts, mark.from)
		end
	end
	table.sort(starts)
	return starts
end

greed.command({
	name = "ui-press",
	doc = "Press the widget at the cursor in a plugin's view, as clicking it does",
	run = function(ctx)
		local entry = mounted[ctx.buffer:id()]
		if entry == nil then
			return
		end
		for _, mark in ctx.buffer:marks_at(ctx.view:cursor()) do
			local data = mark.data
			if mark.action == "ui-press" and type(data) == "table" then
				local press = entry.presses[data.ui]
				if press then
					press()
				end
				return
			end
		end
	end,
})

-- Moves the cursor to the widget `by` (1 or -1) from it, round the ends.
local function step(ctx: greed.Context, by: number)
	local starts = widgets(ctx.buffer)
	if #starts == 0 then
		return
	end
	local here = ctx.view:cursor()
	local to: number
	if by > 0 then
		to = starts[1]
		for _, at in starts do
			if at > here then
				to = at
				break
			end
		end
	else
		to = starts[#starts]
		for i = #starts, 1, -1 do
			if starts[i] < here then
				to = starts[i]
				break
			end
		end
	end
	ctx.view:set_selection({ ranges = { { anchor = to, head = to } }, primary = 1 })
end

greed.command({
	name = "ui-next",
	doc = "Go to the next widget of a plugin's view",
	run = function(ctx)
		step(ctx, 1)
	end,
})

greed.command({
	name = "ui-prev",
	doc = "Go to the widget before in a plugin's view",
	run = function(ctx)
		step(ctx, -1)
	end,
})

greed.on("view.resized", function(event: greed.ViewResized)
	local entry = mounted[event.view:buffer():id()]
	if entry then
		entry.view:redraw()
	end
end)

greed.on("buffer.closed", function(event)
	mounted[event.id] = nil
end)

return M

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
local atomic = require("./atomic")

local width, clip = text_helpers.width, text_helpers.clip

local M = {}

--- Text in a style; `press`, if given, makes it a widget pressing calls.
--- `value` is what its line stands for (a row's thing), found under the
--- cursor with `View:value_at`; `tag` names where it is, for `View:spots`;
--- `line` is a style for the whole line it's on. `marks` are marks of its
--- own, counted from its start, like a bar drawn over its first cell.
export type Span = {
	text: string,
	style: string?,
	press: (() -> ())?,
	value: any?,
	tag: string?,
	line: string?,
	marks: { greed.Mark }?,
}

--- A line of spans.
export type Line = { Span }

--- A part of an interface: its lines, laid out for a width in cells. A
--- column has its `parts`; a keyed part its `key` and `version`.
export type Node = {
	lay: (cells: number) -> { Line },
	parts: { Node }?,
	key: string?,
	version: any?,
}

--- A mounted view: its buffer, its state, and what draws it.
export type View = {
	buffer: greed.Buffer,
	state: { [string]: any },
	--- Merges `patch` into the state and draws the view again.
	set: (self: View, patch: { [string]: any }) -> (),
	--- Merges `patch` (if any) into the state and draws the view again
	--- soon, once for everything set meanwhile, like tokens streaming in.
	soon: (self: View, patch: { [string]: any }?) -> (),
	--- Draws the view again, as its state says now.
	redraw: (self: View) -> (),
	--- Stops drawing it; the buffer stays as it was last drawn.
	unmount: (self: View) -> (),
	--- The value of the line at `pos`, if a span on it has one.
	value_at: (self: View, pos: number) -> any,
	--- The values of its lines, top to bottom.
	values: (self: View) -> { any },
	--- Where the spans tagged `tag` are, as drawn last.
	spots: (self: View, tag: string) -> { { from: number, to: number } },
	--- Calls `f` with each line that has a value (0-based) and its value,
	--- top to bottom.
	each: (self: View, f: (line: number, value: any) -> ()) -> (),
	--- The first line (0-based) whose value `wanted` says yes to.
	line_of: (self: View, wanted: (value: any) -> boolean) -> number?,
	--- The value of 0-based `line`, if it has one.
	value_on: (self: View, line: number) -> any,
	--- Where what's written after it starts, for a view with an input.
	input_start: (self: View) -> number,
	--- What's written after it, for a view with an input.
	input: (self: View) -> string,
}

--- What a drawing says besides its text: each line's value (by 0-based
--- line) and where tagged spans are.
export type Drawn = {
	values: { [number]: any },
	spots: { [string]: { { from: number, to: number } } },
}

--- A span of `text`, in `style`.
function M.span(text: string, style: string?): Span
	return { text = text, style = style }
end

--- One line of `spans`. A view wraps it where it's wider, as any long line;
--- in a `row`, it's cut at its column's width.
function M.line(spans: { Span }): Node
	return {
		lay = function(_cells: number): { Line }
			return { table.clone(spans) }
		end,
	}
end

-- `line` cut at `cells` wide.
local function fit(line: Line, cells: number): Line
	local out: Line = {}
	local room = cells
	for _, span in line do
		if room <= 0 then
			break
		end
		local cut = table.clone(span)
		cut.text = clip(span.text, room)
		room -= width(cut.text)
		table.insert(out, cut)
	end
	return out
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
		parts = children,
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

--- A part `build` makes, laid out again only when `version` or the width
--- changes; until then a view keeps its lines, its marks and its place in
--- the buffer as they are. A history of messages, each keyed by its id and
--- versioned by its length, draws only the one streaming in. Keys are the
--- view's own, one per part; a part is kept among a column's parts.
function M.keyed(key: string, version: any, build: () -> Node): Node
	return {
		key = key,
		version = version,
		lay = function(cells: number): { Line }
			return build().lay(cells)
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
--- unless `widths` says how wide each is (the last taking what's left), or
--- with `fit` each as wide as it is, as a row of buttons.
function M.row(
	children: { Node },
	opts: { gap: number?, widths: { number }?, fit: boolean? }?
): Node
	local gap = (opts and opts.gap) or 2
	local fixed: { number } = (opts and opts.widths) or {}
	local fitted = opts ~= nil and opts.fit == true
	return {
		lay = function(cells: number): { Line }
			local n = #children
			local each = math.max((cells - gap * (n - 1)) // math.max(n, 1), 1)
			local widths: { number } = {}
			local used = 0
			for i = 1, n do
				local given = fixed[i]
				if fitted then
					given = 1
					for _, line in children[i].lay(cells) do
						given = math.max(given, line_width(line))
					end
				end
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
					local part = fit(laid[i][r] or {}, widths[i])
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
			for _, laid in child.lay(inner) do
				local line = fit(laid, inner)
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

--- A button: its label in the theme's `ui.button` (a badge in the window),
--- calling `on_press` when pressed.
function M.button(label: string, on_press: () -> ()): Node
	return M.line({ { text = ` {label} `, style = "ui.button", press = on_press } })
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

--- A row of a grid: its cells, each some spans; what the row stands for
--- (`value`, under the cursor anywhere on its line); a style for its line.
export type GridRow = { cells: { { Span } }, value: any?, line: string? }

--- `rows` lined up in columns `gap` cells apart (2), without borders, like
--- a list of things with a few facts each. Each column is as wide as its
--- widest cell; a line ends where its last cell does.
function M.grid(rows: { GridRow }, opts: { gap: number? }?): Node
	local gap = (opts and opts.gap) or 2
	return {
		lay = function(_cells: number): { Line }
			local widths: { number } = {}
			for _, row in rows do
				for c, cell in row.cells do
					widths[c] = math.max(widths[c] or 0, line_width(cell))
				end
			end
			local out: { Line } = {}
			for _, row in rows do
				local line: Line = {}
				-- Cells up to the last one with something in it.
				local last = #row.cells
				while last > 0 and line_width(row.cells[last]) == 0 do
					last -= 1
				end
				for c = 1, last do
					local cell = row.cells[c]
					for _, span in cell do
						local placed = table.clone(span)
						placed.value = row.value
						table.insert(line, placed)
					end
					if c < last then
						local pad = widths[c] - line_width(cell) + gap
						table.insert(line, { text = string.rep(" ", pad), value = row.value })
					end
				end
				if #line == 0 then
					table.insert(line, { text = "", value = row.value })
				end
				line[1].line = row.line
				table.insert(out, line)
			end
			return out
		end,
	}
end

--- `text` as spans, the characters at `matched` (byte offsets, as
--- `greed.fuzzy_positions` gives them) in `style` ("ui.menu.match"), the
--- rest in `rest`: how a menu shows what a search matched.
function M.matched(text: string, matched: { number }, style: string?, rest: string?): { Span }
	local hit: { [number]: boolean } = {}
	for _, at in matched do
		hit[at] = true
	end
	local out: { Span } = {}
	local run: string, on = "", false
	for at, code in utf8.codes(text) do
		local now = hit[at - 1] == true
		if now ~= on and run ~= "" then
			table.insert(out, { text = run, style = if on then style or "ui.menu.match" else rest })
			run = ""
		end
		run ..= utf8.char(code)
		on = now
	end
	if run ~= "" or #out == 0 then
		table.insert(
			out,
			{ text = run :: string, style = if on then style or "ui.menu.match" else rest }
		)
	end
	return out
end

--- `items` one a line, each drawn as `spans(item)`, the item its line's
--- value. Pressing a line calls `open` with its item. The `current` one
--- (by index) is marked as a menu marks its selected row, for a list
--- whose cursor is somewhere else, like in a picker's query.
function M.list<T>(
	items: { T },
	spans: (item: T) -> { Span },
	opts: { open: ((item: T) -> ())?, current: number? }?
): Node
	local open = opts and opts.open
	local current = opts and opts.current
	local lines: { Node } = {}
	for i, item in items do
		local parts = spans(item)
		for _, span in parts do
			span.value = item
			if open then
				span.press = function()
					open(item)
				end
			end
		end
		if i == current then
			if #parts == 0 then
				table.insert(parts, { text = "", value = item })
			end
			parts[1].line = "ui.menu.selected"
		end
		table.insert(lines, M.line(parts))
	end
	return M.column(lines)
end

-- Some lines drawn: their text and marks, from 0 at the first line's
-- start; each pressable span a mark whose action is `ui-press`, its data
-- the index of what it does in `presses`; each line's value by 0-based
-- line, and where tagged spans are. A keyed part's also says what it was
-- drawn for.
type Piece = {
	text: string,
	lines: { string },
	marks: { greed.Mark },
	presses: { () -> () },
	values: { [number]: any },
	spots: { [string]: { { from: number, to: number } } },
	key: string?,
	version: any,
	cells: number?,
}

local function piece_of(lines: { Line }): Piece
	local texts: { string } = {}
	local piece: Piece = {
		text = "",
		lines = texts,
		marks = {},
		presses = {},
		values = {},
		spots = {},
	}
	local marks, presses, values, spots = piece.marks, piece.presses, piece.values, piece.spots
	local at = 0
	for n, line in lines do
		local parts: { string } = {}
		local start = at
		local line_style: string? = nil
		for _, span in line do
			local from = at
			at += #span.text
			table.insert(parts, span.text)
			if span.value ~= nil and values[n - 1] == nil then
				values[n - 1] = span.value
			end
			line_style = line_style or span.line
			local tag = span.tag
			if tag then
				local list = spots[tag] or {}
				spots[tag] = list
				table.insert(list, { from = from, to = at })
			end
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
			if span.marks then
				for _, mark in span.marks do
					local moved = table.clone(mark)
					moved.from += from
					moved.to += from
					table.insert(marks, moved)
				end
			end
		end
		if line_style then
			table.insert(
				marks,
				{ from = start, to = at, style = line_style :: string, line = true }
			)
		end
		table.insert(texts, table.concat(parts))
		at += 1
	end
	piece.text = table.concat(texts, "\n")
	return piece
end

--- `node` as text and marks for `cells` wide: each pressable span a mark
--- whose action is `ui-press`, with its index in `presses`; and what else
--- the drawing says (`Drawn`).
function M.draw(node: Node, cells: number): (string, { greed.Mark }, { () -> () }, Drawn)
	local piece = piece_of(node.lay(cells))
	return piece.text, piece.marks, piece.presses, { values = piece.values, spots = piece.spots }
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

-- `node` laid out `cells` wide as pieces, top to bottom: each keyed part
-- one, taken from `cache` if it was drawn for the same version and width,
-- and the lines between them one each. Every keyed piece goes in `seen`.
local function flatten(
	node: Node,
	cells: number,
	cache: { [string]: Piece },
	seen: { [string]: Piece }
): { Piece }
	local out: { Piece } = {}
	local loose: { Line } = {}
	local function flush()
		if #loose > 0 then
			table.insert(out, piece_of(loose))
			loose = {}
		end
	end
	local function walk(part: Node)
		local key = part.key
		if key ~= nil then
			flush()
			local piece = cache[key]
			if piece == nil or piece.version ~= part.version or piece.cells ~= cells then
				piece = piece_of(part.lay(cells))
				piece.key, piece.version, piece.cells = key, part.version, cells
			end
			seen[key] = piece
			if #piece.lines > 0 then
				table.insert(out, piece)
			end
		elseif part.parts then
			for _, child in part.parts do
				walk(child)
			end
		else
			for _, line in part.lay(cells) do
				table.insert(loose, line)
			end
		end
	end
	walk(node)
	flush()
	return out
end

-- Makes lines `first` to `last_a` (1-based) of the `total_a` lines of
-- `buffer` from 0-based line `base` on, which end at byte `stop`, read as
-- lines `first` to `last_b` of the `total_b` that `new(i)` gives, as one
-- edit of the lines that differ. A cursor in what's replaced stays on its
-- line and column, rather than going to either end of the new text.
local function replace_lines(
	buffer: greed.Buffer,
	base: number,
	stop: number,
	total_a: number,
	total_b: number,
	first: number,
	last_a: number,
	last_b: number,
	new: (i: number) -> string
)
	-- Line `i` of them, 0-based in the buffer.
	local function at(i: number): number
		return base + i - 1
	end
	local function old(i: number): string
		return buffer:slice(buffer:line_start(at(i)), buffer:line_end(at(i)))
	end
	while first <= last_a and first <= last_b and old(first) == new(first) do
		first += 1
	end
	while last_a >= first and last_b >= first and old(last_a) == new(last_b) do
		last_a -= 1
		last_b -= 1
	end
	if last_a < first and last_b < first then
		return
	end
	-- Lines `first` to `last_a` of the old text become `first` to `last_b`.
	local from = if first <= total_a then buffer:line_start(at(first)) else stop
	local to = if last_a >= first then buffer:line_end(at(last_a)) else from
	local lines: { string } = {}
	for i = first, last_b do
		table.insert(lines, new(i))
	end
	local text = table.concat(lines, "\n")
	if last_a < first then
		-- Only lines added: they join with a line break on the right side.
		text = if first <= total_a then text .. "\n" else "\n" .. text
	elseif last_b < first then
		-- Only lines taken away, with the line break before or after them.
		if first > 1 then
			from = buffer:line_end(at(first - 1))
		elseif last_a < total_a then
			to = buffer:line_start(at(last_a + 1))
		end
	end
	local inside: { { view: greed.View, line: number, column: number } } = {}
	for _, shown in buffer:views() do
		local pos = shown:cursor()
		if pos >= from and pos <= to then
			local line = buffer:line_of(pos)
			table.insert(
				inside,
				{ view = shown, line = line, column = pos - buffer:line_start(line) }
			)
		end
	end
	buffer:edit(function(e)
		e:replace(from, to, text)
	end, { undo = false })
	for _, kept in inside do
		local line = math.min(kept.line, buffer:line_count() - 1)
		local pos = math.min(buffer:line_start(line) + kept.column, buffer:line_end(line))
		kept.view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	end
end

-- A piece where it's drawn: where it starts (byte and 0-based line) and
-- the ids its widgets' presses have.
type Placed = { piece: Piece, at: number, line: number, ids: { number } }

-- What's mounted, by buffer id: its view, what each widget does by id, the
-- pieces drawn and the keyed ones to reuse.
type Mounted = {
	view: View,
	presses: { [number]: () -> () },
	next: number,
	placed: { Placed },
	cache: { [string]: Piece },
	--- The namespace of its marks.
	ns: string,
	--- Whether what's after it is an input, written there and kept.
	input: boolean,
	--- Whether its first line is an input instead, drawn below it.
	above: boolean,
}

-- Where what `placed` draws ends, from where it starts.
local function end_of(placed: { Placed }): number
	local last = placed[#placed]
	return if last then last.at + #last.piece.text else 0
end

-- Where `entry`'s view starts in `buffer`: the byte, and the 0-based line.
-- Its pieces' places count from there.
local function base(entry: Mounted, buffer: greed.Buffer): (number, number)
	if entry.above then
		return buffer:line_end(0) + 1, 1
	end
	return 0, 0
end

local mounted: { [number]: Mounted } = {}

-- `piece`'s marks for it drawn at `at`, its widgets given ids in `entry`.
local function marks_of(entry: Mounted, piece: Piece, at: number): ({ greed.Mark }, { number })
	local ids: { number } = {}
	for i, press in piece.presses do
		entry.next += 1
		entry.presses[entry.next] = press
		ids[i] = entry.next
	end
	local out: { greed.Mark } = {}
	for _, mark in piece.marks do
		local moved = table.clone(mark)
		moved.from += at
		moved.to += at
		local data: any = mark.data
		if mark.action == "ui-press" and data then
			moved.data = { ui = ids[data.ui] }
		end
		table.insert(out, moved)
	end
	return out, ids
end

local function forget_presses(entry: Mounted, placed: Placed)
	for _, id in placed.ids do
		entry.presses[id] = nil
	end
end

-- The one of `placed` drawn at 0-based `line`, if any.
local function placed_at(placed: { Placed }, line: number): Placed?
	local lo, hi = 1, #placed
	while lo <= hi do
		local mid = (lo + hi) // 2
		local p = placed[mid]
		if line < p.line then
			hi = mid - 1
		elseif line >= p.line + #p.piece.lines then
			lo = mid + 1
		else
			return p
		end
	end
	return nil
end

-- Draws `pieces` in `buffer` where `entry`'s were, changing only the text
-- and marks of the pieces that changed: a piece kept as it was (the same
-- keyed piece) keeps its lines and marks as they are.
local function place(buffer: greed.Buffer, entry: Mounted, pieces: { Piece })
	local old = entry.placed
	local function same(a: Piece, b: Piece): boolean
		return a == b or (a.key == nil and b.key == nil and a.text == b.text)
	end
	local head = 0
	while head < #old and head < #pieces and same(old[head + 1].piece, pieces[head + 1]) do
		head += 1
	end
	local tail = 0
	while
		tail < #old - head
		and tail < #pieces - head
		and same(old[#old - tail].piece, pieces[#pieces - tail])
	do
		tail += 1
	end
	-- The new pieces' places, and each line's text by number.
	local placed: { Placed } = {}
	local at, count = 0, 0
	for i, piece in pieces do
		placed[i] = { piece = piece, at = at, line = count, ids = {} }
		count += #piece.lines
		at += #piece.text + 1
	end
	local function new(i: number): string
		local p = placed_at(placed, i - 1)
		return if p then p.piece.lines[i - p.line] else ""
	end
	local function marks_from(from_index: number, to_index: number): { greed.Mark }
		local start = base(entry, buffer)
		local marks: { greed.Mark } = {}
		for i = from_index, to_index do
			local own, ids = marks_of(entry, placed[i].piece, start + placed[i].at)
			placed[i].ids = ids
			table.move(own, 1, #own, #marks + 1, marks)
		end
		return marks
	end
	-- What the view says of its lines holds from the edit on, for those it
	-- tells about the change.
	entry.placed = placed
	if #old == 0 or #pieces == 0 then
		local lines: { string } = {}
		for i = 1, count do
			table.insert(lines, new(i))
		end
		local text = table.concat(lines, "\n")
		if entry.input and #old == 0 then
			-- Drawn first above what's written there.
			if #pieces > 0 then
				buffer:edit(function(e)
					e:replace(0, 0, text .. "\n")
				end, { undo = false })
			end
		elseif entry.input then
			-- Nothing to draw now: only what's written there is left.
			local stop = end_of(old) + 1
			buffer:edit(function(e)
				e:replace(0, stop, "")
			end, { undo = false })
		elseif entry.above and #old == 0 then
			-- Drawn first under the line that's written in.
			buffer:edit(function(e)
				e:replace(buffer:line_end(0), buffer:len(), "\n" .. text)
			end, { undo = false })
		else
			-- Nothing drawn before (or now): the buffer is whatever it holds.
			local total, wanted = buffer:line_count(), math.max(count, 1)
			replace_lines(buffer, 0, buffer:len(), total, wanted, 1, total, wanted, new)
		end
		for _, was in old do
			forget_presses(entry, was)
		end
		buffer:decorate(entry.ns, marks_from(1, #placed))
		return
	end
	local total_a = old[#old].line + #old[#old].piece.lines
	local kept_after = 0
	for i = #old - tail + 1, #old do
		kept_after += #old[i].piece.lines
	end
	local first = (if head > 0 then placed[head].line + #pieces[head].lines else 0) + 1
	local start, line = base(entry, buffer)
	replace_lines(
		buffer,
		line,
		start + end_of(old),
		total_a,
		count,
		first,
		total_a - kept_after,
		count - kept_after,
		new
	)
	-- Marks: the changed pieces' as one, and those of a piece of loose lines
	-- that read the same but were drawn again.
	for i = head + 1, #old - tail do
		forget_presses(entry, old[i])
	end
	local function redecorate(from_index: number, to_index: number)
		local last = placed[to_index]
		local from = base(entry, buffer)
		-- To the line break after it, where a mark of a piece taken away
		-- may have been squeezed.
		local stop = from + last.at + #last.piece.text + 1
		buffer:decorate(
			entry.ns,
			marks_from(from_index, to_index),
			{ from = from + placed[from_index].at, to = stop }
		)
	end
	for i, p in placed do
		local was = if i <= head
			then old[i]
			elseif i > #pieces - tail then old[#old - (#pieces - i)]
			else nil
		if was and was.piece == p.piece then
			p.ids = was.ids
		elseif was then
			forget_presses(entry, was)
			redecorate(i, i)
		end
	end
	if head + 1 <= #pieces - tail then
		redecorate(head + 1, #pieces - tail)
	end
end

-- The value of 0-based `line` of `entry`'s view.
local function value_of(entry: Mounted, line: number): any
	local own = line - (if entry.above then 1 else 0)
	local p = placed_at(entry.placed, own)
	return if p then p.piece.values[own - p.line] else nil
end

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

-- How long `View:soon` waits to draw, gathering what's set meanwhile.
local SOON_MS = 16

--- Draws `render(state)` into `buffer` for the width of its views, and
--- again whenever the state is set or a view of it is resized. Gives the
--- view, whose `set` merges into its state. With `key`, which names a
--- line's value, each cursor stays on the line of the same value as the
--- lines change places, like a list's row as it's sorted again.
---
--- Drawing again changes only the lines that changed, and a `keyed` part
--- whose version is the same isn't laid out again at all, so a long view
--- that changes at one end costs what that end does.
---
--- Its marks go in namespace `ns` ("ui"); `width` says how many cells wide
--- to lay it out (`M.width`). With `input`, it's drawn at the start of the
--- buffer and what's written after it is an input, like a chat's box: kept
--- as it is, the view read-only before it. With `above` too, the buffer's
--- first line is the input instead, like a picker's query, and the view is
--- drawn under it, its lines counted from the buffer's. With `keys` false it leaves the
--- buffer's keys (tab and shift-tab to go between widgets) to its plugin.
--- `after` is called after each drawing before a frame shows it, to draw
--- what goes with it; it can't wait. With `draw` false it's first drawn at
--- the first `redraw` or `set`, so it can be mounted while what `render`
--- reads is still being made.
function M.mount(
	buffer: greed.Buffer,
	render: (state: { [string]: any }) -> Node,
	state: { [string]: any }?,
	opts: {
		key: ((value: any) -> string)?,
		ns: string?,
		width: ((buffer: greed.Buffer) -> number)?,
		input: boolean?,
		above: boolean?,
		keys: boolean?,
		after: ((view: View) -> ())?,
		draw: boolean?,
	}?
): View
	local key = opts and opts.key
	local width_of = opts and opts.width or M.width
	-- An input under it, or over it.
	local above = opts ~= nil and opts.input == true and opts.above == true
	local input = opts ~= nil and opts.input == true and not above
	local after = opts and opts.after
	local entry: Mounted
	local view: View
	-- Each view's cursor: its line's value's key, and how far along it.
	local function held(): { { view: greed.View, key: string, column: number } }
		local out = {}
		if key == nil then
			return out
		end
		for _, shown in buffer:views() do
			local pos = shown:cursor()
			local line = buffer:line_of(pos)
			local value = value_of(entry, line)
			if value ~= nil then
				table.insert(
					out,
					{ view = shown, key = key(value), column = pos - buffer:line_start(line) }
				)
			end
		end
		return out
	end
	local function line_keyed(wanted: string): number?
		return view:line_of(function(value: any): boolean
			return (key :: (any) -> string)(value) == wanted
		end)
	end
	local soon = false
	view = {
		buffer = buffer,
		state = state or {},
		set = function(self: View, patch: { [string]: any })
			for k, v in patch do
				self.state[k] = v
			end
			self:redraw()
		end,
		soon = function(self: View, patch: { [string]: any }?)
			if patch then
				for k, v in patch do
					self.state[k] = v
				end
			end
			if soon then
				return
			end
			soon = true
			greed.spawn(function()
				greed.sleep(SOON_MS)
				soon = false
				self:redraw()
			end)
		end,
		redraw = function(self: View)
			if mounted[buffer:id()] ~= entry or entry.view ~= self or not buffer:valid() then
				return
			end
			local cursors = held()
			local seen: { [string]: Piece } = {}
			local pieces = flatten(render(self.state), width_of(buffer), entry.cache, seen)
			entry.cache = seen
			if above and #pieces == 0 then
				-- An empty line, for the input to come before.
				pieces = { piece_of({ {} }) }
			end
			local first = #entry.placed == 0
			-- No frame shows the new text with the old marks.
			atomic(function()
				place(buffer, entry, pieces)
				if input then
					buffer:set_readonly_before(self:input_start())
				elseif first then
					-- The first drawing went in at the cursor, which it
					-- pushed to the end: back to the top, or the input's end.
					local pos = if above then buffer:line_end(0) else 0
					for _, shown in buffer:views() do
						shown:set_selection({
							ranges = { { anchor = pos, head = pos } },
							primary = 1,
						})
					end
				end
				if after then
					after(self)
				end
			end)
			for _, cursor in cursors do
				local line = line_keyed(cursor.key)
				if line and cursor.view:valid() then
					local pos =
						math.min(buffer:line_start(line) + cursor.column, buffer:line_end(line))
					cursor.view:set_selection({
						ranges = { { anchor = pos, head = pos } },
						primary = 1,
					})
				end
			end
		end,
		unmount = function(self: View)
			if mounted[buffer:id()] == entry and entry.view == self then
				mounted[buffer:id()] = nil
			end
		end,
		value_at = function(_self: View, pos: number): any
			return value_of(entry, buffer:line_of(pos))
		end,
		values = function(_self: View): { any }
			local out: { any } = {}
			for _, p in entry.placed do
				for line = 0, #p.piece.lines - 1 do
					local value = p.piece.values[line]
					if value ~= nil then
						table.insert(out, value)
					end
				end
			end
			return out
		end,
		spots = function(_self: View, tag: string): { { from: number, to: number } }
			local out: { { from: number, to: number } } = {}
			local start = base(entry, buffer)
			for _, p in entry.placed do
				local spots = p.piece.spots[tag]
				if spots then
					for _, spot in spots do
						local at = start + p.at
						table.insert(out, { from = at + spot.from, to = at + spot.to })
					end
				end
			end
			return out
		end,
		each = function(_self: View, f: (line: number, value: any) -> ())
			local first = if entry.above then 1 else 0
			for _, p in entry.placed do
				for line = 0, #p.piece.lines - 1 do
					local value = p.piece.values[line]
					if value ~= nil then
						f(first + p.line + line, value)
					end
				end
			end
		end,
		line_of = function(_self: View, wanted: (value: any) -> boolean): number?
			local first = if entry.above then 1 else 0
			for _, p in entry.placed do
				for line = 0, #p.piece.lines - 1 do
					local value = p.piece.values[line]
					if value ~= nil and wanted(value) then
						return first + p.line + line
					end
				end
			end
			return nil
		end,
		value_on = function(_self: View, line: number): any
			return value_of(entry, line)
		end,
		input_start = function(_self: View): number
			if entry.above or #entry.placed == 0 then
				return 0
			end
			return math.min(end_of(entry.placed) + 1, buffer:len())
		end,
		input = function(self: View): string
			if entry.above then
				return buffer:slice(0, buffer:line_end(0))
			end
			return buffer:slice(self:input_start(), buffer:len())
		end,
	}
	entry = {
		view = view,
		presses = {},
		next = 0,
		placed = {},
		cache = {},
		ns = opts and opts.ns or "ui",
		input = input,
		above = above,
	}
	mounted[buffer:id()] = entry
	if not (opts and opts.keys == false) then
		buffer:set_keys({ tab = "ui-next", ["shift-tab"] = "ui-prev" })
	end
	greed.plugin.tie(function()
		view:unmount()
	end)
	if not (opts and opts.draw == false) then
		view:redraw()
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
	local entry = mounted[buffer:id()]
	for _, mark in buffer:decorations(if entry then entry.ns else "ui") do
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

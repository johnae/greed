-- Indent guides: a thin line at each level of indent, so you can see the
-- lines a block holds. Blank lines inside a block get them too, except one
-- a cursor is on, where they'd sit in the way of typing. `:set
-- indent-guides false` turns them off; their style is "ui.indent.guide".
--
-- Rulers, at the columns the `rulers` option names, go the same way: where
-- nothing is written at their column, in "ui.ruler".

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "indent-guides",
	doc = "Show a line at each level of indent",
	default = true,
})

local GUIDE = "│"
local STYLE = "ui.indent.guide"

-- How far to look past the lines drawn for the indent of the lines a
-- blank one sits between.
local LOOK = 200

local M = {}

-- How many columns `lead` (a line's leading blanks) takes, tabs reaching
-- the next stop `tab` apart.
local function columns(lead: string, tab: number): number
	local col = 0
	for i = 1, #lead do
		if string.byte(lead, i) == 9 then
			col += tab - col % tab
		else
			col += 1
		end
	end
	return col
end

-- The indent of line `n` in columns, or nil for a blank line.
local function indent_of(buffer: greed.Buffer, n: number, tab: number): number?
	local text = buffer:line_text(n)
	local lead = string.match(text, "^[ \t]*") :: string
	if #lead == #text then
		return nil
	end
	return columns(lead, tab)
end

--- The columns a line indented `cols` deep has guides at, a level `step`
--- columns apart: every level short of where its text starts.
function M.guides(cols: number, step: number): { number }
	local out = {}
	local col = 0
	while col < cols do
		table.insert(out, col)
		col += step
	end
	return out
end

-- The marks for `glyph` in `style` at `cols` (0-based, in order) on line
-- `n`, whose text is `text`: over a blank where the column has one, and
-- past the line's end for the rest, after the `after` columns marks before
-- these already show there. Text already there wins. Returns how many
-- columns past the end are shown now.
local function marks_for(
	buffer: greed.Buffer,
	n: number,
	text: string,
	cols: { number },
	tab: number,
	out: { greed.Mark },
	glyph: string,
	style: string,
	after: number
): number
	local last = cols[#cols]
	if last == nil then
		return after
	end
	local start = buffer:line_start(n)
	-- The byte each column starts at over the line's blanks, and whether
	-- it's a tab, as far as the last column: a long line isn't read to its
	-- end.
	local at: { [number]: number } = {}
	local tabs: { [number]: boolean } = {}
	local col, byte = 0, 0
	for char in string.gmatch(text, utf8.charpattern) do
		if col > last then
			break
		end
		local is_tab = char == "\t"
		if is_tab or char == " " then
			at[col], tabs[col] = byte, is_tab
		end
		col += if is_tab then tab - col % tab else core.text.width(char)
		byte += #char
	end
	local past = ""
	for _, guide in cols do
		local blank = at[guide]
		if blank then
			-- Over a space; before a tab, which still reaches its stop.
			table.insert(out, {
				from = start + blank,
				to = start + blank + 1,
				style = style,
				text = glyph,
				overlay = not tabs[guide],
			})
		elseif guide >= col + after + core.text.width(past) then
			past ..= string.rep(" ", guide - col - after - core.text.width(past)) .. glyph
		end
	end
	if past ~= "" then
		local finish = start + #text
		-- Start at the newline without a separator or an inline cursor stop.
		table.insert(
			out,
			{ from = finish, to = finish, style = style, text = past, eol = true, eol_space = false }
		)
	end
	return after + core.text.width(past)
end

greed.option.define({
	name = "rulers",
	doc = 'Columns to show a ruler at, counted from 1, like "80,100"; empty for none',
	default = "",
})

-- The rulers option as 0-based columns, in order.
local function rulers(): { number }
	local cols = {}
	for n in string.gmatch(tostring(greed.option.get("rulers")), "%d+") do
		table.insert(cols, tonumber(n) :: number - 1)
	end
	table.sort(cols)
	return cols
end

-- The lines with a cursor on them in `buffer`'s views.
local function cursor_lines(buffer: greed.Buffer): { [number]: boolean }
	local lines = {}
	for _, view in buffer:views() do
		for _, range in view:selection().ranges do
			lines[buffer:line_of(range.head)] = true
		end
	end
	return lines
end

-- Guides and rulers are drawn together, so rulers past a line's end come
-- after the guides there.
local redraw = core.visible.add({
	ns = "indent-guides",
	-- A blank line a cursor is on has no guides.
	cursor = true,
	wants = function(buffer: greed.Buffer): boolean
		return buffer:kind() == "file"
			and (greed.option.get("indent-guides") == true or #rulers() > 0)
	end,
	draw = function(buffer: greed.Buffer, first: number, last: number): { greed.Mark }
		local guides_on = greed.option.get("indent-guides") == true
		local ruler_cols = rulers()
		local tab = buffer:tab_width()
		local unit = core.indent.unit(buffer)
		local step = if unit == "\t" then tab else math.max(1, #unit)
		local cursors = cursor_lines(buffer)
		local count = buffer:line_count()
		local marks: { greed.Mark } = {}
		-- The indent of the last line with text above, and of the next
		-- below, for blank lines in between.
		local above: number? = nil
		for n = first - 1, math.max(0, first - LOOK), -1 do
			above = indent_of(buffer, n, tab)
			if above then
				break
			end
		end
		local below: number? = nil
		local below_line = -1
		for n = first, last do
			local text = buffer:line_text(n)
			local lead = string.match(text, "^[ \t]*") :: string
			local cols: number
			if #lead < #text then
				cols = columns(lead, tab)
				above = cols
			elseif not guides_on or cursors[n] then
				cols = 0
			else
				if below_line < n then
					below = nil
					below_line = math.min(count - 1, last + LOOK)
					for m = n + 1, below_line do
						below = indent_of(buffer, m, tab)
						if below then
							below_line = m
							break
						end
					end
				end
				cols = math.min(above or 0, below or 0)
			end
			local guide_cols = if guides_on then M.guides(cols, step) else {}
			local after = marks_for(buffer, n, text, guide_cols, tab, marks, GUIDE, STYLE, 0)
			marks_for(buffer, n, text, ruler_cols, tab, marks, "┊", "ui.ruler", after)
		end
		return marks
	end,
})

greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "indent-guides" or event.name == "rulers" then
		redraw()
	end
end)

return M

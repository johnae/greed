-- Peeking at a block: a float onto the shell's own buffer, at the block,
-- so what works on a block there works in it too: `/` filters it, `enter`
-- on a row acts on what the row is, `space .` lists the rest, `ctrl-c`
-- stops it. A live block's peek follows it as it shows what's new. `esc`
-- closes it, keeping any filter.
--
-- A peek opened on purpose (`enter` on a running block's line, "open in a
-- float", `follow logs`) is kept: a float of the tab, one for each block,
-- open as long as you like while you work elsewhere, to keep an eye on
-- things; the tab's float layouts (`alt-w`) arrange them. The one the
-- mouse opens resting on a folded block is passing: one at a time, gone
-- when the mouse moves away.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")

type Shell = state.Shell
type Block = state.Block

local M = {}

-- `tail` while the cursor is on the block's last line, so it stays on the
-- last line as more comes, like `tail -f`. A `kept` one stays the size it
-- opened at, or was given, rather than growing with its block.
type Peek = {
	view: greed.View,
	shell: Shell,
	block: Block,
	line: number,
	height: number,
	tail: boolean,
	kept: boolean,
	-- Never follows the last line, as asked with `tail = false`: it shows its
	-- block from the top however it grows.
	still: boolean,
}

-- The peeks open, the oldest first.
local peeks: { Peek } = {}

local function find(view: greed.View): Peek?
	for _, p in peeks do
		if p.view == view then
			return p
		end
	end
	return nil
end

--- The block `view` peeks at, when it's a peek.
function M.of(view: greed.View): Block?
	local p = find(view)
	return if p and view:valid() then p.block else nil
end

--- Closes the peek `view` is, or with no `view` the passing one (the
--- mouse's); false when there's none.
function M.close(view: greed.View?): boolean
	for i = #peeks, 1, -1 do
		local p = peeks[i]
		if if view then p.view == view else not p.kept then
			table.remove(peeks, i)
			if p.view:valid() then
				p.view:close()
				return true
			end
			return false
		end
	end
	return false
end

-- How tall a float showing all of `block` is, borders included, within
-- reason; 0 once its text is gone.
local function height(shell: Shell, block: Block): number
	local from, to = log.range(block)
	if from == nil or to == nil then
		return 0
	end
	local buffer = shell.buffer
	return math.clamp(buffer:line_of(to) - buffer:line_of(from) + 2, 5, 30)
end

-- Whether `p`'s float still shows its shell: one where a file was opened
-- shows that instead, and is left as it is.
local function shows_shell(p: Peek): boolean
	return p.view:valid() and p.view:buffer() == p.shell.buffer
end

-- Keeps `p`'s cursor on its block, where the float can show it, and notes
-- whether it's on the last line.
local function keep_cursor(p: Peek)
	local from, to = log.range(p.block)
	if from == nil or to == nil or not shows_shell(p) then
		return
	end
	local buffer = p.shell.buffer
	-- The block's last character, which may take several bytes (a table
	-- nu drew ends in `╯`).
	local last = if to > from then buffer:prev_char(to) else from
	local cursor = p.view:cursor()
	if cursor < from or cursor >= to then
		cursor = if cursor < from then from else last
		p.view:set_cursor(cursor)
	end
	p.tail = not p.still and buffer:line_of(cursor) == buffer:line_of(last)
end

-- Fits `p`'s float to its block, showing none of the shell around it, and
-- scrolls its view back to the block's command when it moved.
local function fit(p: Peek)
	local from, to = log.range(p.block)
	if from == nil or to == nil or not shows_shell(p) then
		return
	end
	local buffer = p.shell.buffer
	local line = buffer:line_of(from)
	local last = buffer:line_of(math.max(to - 1, from))
	p.view:narrow(line, last)
	if p.tail then
		p.view:set_cursor(buffer:line_start(last))
	end
	keep_cursor(p)
	local tall = height(p.shell, p.block)
	if tall ~= p.height and not p.kept then
		p.view:configure({ height = tall })
		p.height = tall
	end
	if line ~= p.line then
		p.view:set_scroll(line)
	end
	p.line = line
end

--- How a peek opens: passing, without taking focus (`focus = false`, as
--- when the mouse rests on a block), at screen row `y`, and with `tail` on
--- the block's last line, following it as it grows.
export type How = { focus: boolean?, y: number?, tail: boolean? }

--- Opens a float at `block` of `shell`, with the cursor on its first line
--- of output (or its last, with `tail`). One that takes focus is kept, and
--- goes to the one kept for `block` already, if there's one; a passing one
--- takes the place of the passing one open.
function M.open(shell: Shell, block: Block, how: How?): greed.View?
	local focus = how == nil or how.focus ~= false
	local tail = how ~= nil and how.tail == true
	if focus then
		for _, p in peeks do
			if p.kept and p.block == block and p.view:valid() then
				p.view:raise()
				p.view:focus()
				if tail then
					p.tail = true
					fit(p)
				end
				greed.mode.set(core.style.home())
				return p.view
			end
		end
	else
		M.close()
	end
	local from = log.range(block)
	local tall = height(shell, block)
	if from == nil or tall == 0 then
		return nil
	end
	-- Each kept one opens a little below and right of the one before, so
	-- they don't hide each other until they're arranged.
	local kept = #peeks
	local view = greed.float(shell.buffer, {
		title = string.match(block.command, "^[^\n]*") or block.command,
		width = if focus then "70%" else "90%",
		height = tall,
		focus = focus,
		tab = focus,
		x = if focus then 4 + 4 * (kept % 8) else nil,
		y = if focus then 2 + 2 * (kept % 8) else how and how.y,
		footer = "/ filter · enter or space . on a row · ctrl-c stops · esc closes",
	})
	view:set_cursor(log.output_range(shell, block) or from)
	local p: Peek = {
		view = view,
		shell = shell,
		block = block,
		line = -1,
		height = tall,
		tail = tail,
		kept = focus,
		still = how ~= nil and how.tail == false,
	}
	table.insert(peeks, p)
	fit(p)
	if focus then
		greed.mode.set(core.style.home())
	end
	return view
end

--- After `block` shows something new: the peeks at it follow it, and
--- scroll back to it when what's above it moved it; a passing one grows
--- and shrinks with it. Once the block is gone, they close.
function M.follow(block: Block)
	for _, p in table.clone(peeks) do
		if p.block == block then
			if log.range(block) == nil then
				M.close(p.view)
			else
				fit(p)
			end
		end
	end
end

log.on_update(M.follow)

greed.on("selection.changed", function(event: greed.SelectionChanged)
	local p = find(event.view)
	if p then
		keep_cursor(p)
	end
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	for i = #peeks, 1, -1 do
		if peeks[i].view:id() == event.view then
			table.remove(peeks, i)
		end
	end
end)

return M

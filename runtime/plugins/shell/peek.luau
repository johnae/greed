-- Peeking at a block: a float onto the shell's own buffer, at the block,
-- so what works on a block there works in it too: `/` filters it, `enter`
-- on a row acts on what the row is, `space .` lists the rest, `ctrl-c`
-- stops it. A live block's peek follows it as it shows what's new. `esc`
-- closes it, keeping any filter. One is open at a time.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")

type Shell = state.Shell
type Block = state.Block

local M = {}

-- `tail` while the cursor is on the block's last line, so it stays on the
-- last line as more comes, like `tail -f`.
type Peek = {
	view: greed.View,
	shell: Shell,
	block: Block,
	line: number,
	height: number,
	tail: boolean,
}

local open: Peek? = nil

--- The block `view` peeks at, when it's a peek.
function M.of(view: greed.View): Block?
	local p = open
	if p and p.view == view and view:valid() then
		return p.block
	end
	return nil
end

--- Closes the peek, if one is open; false when none is.
function M.close(): boolean
	local p = open
	open = nil
	if p and p.view:valid() then
		p.view:close()
		return true
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

-- Keeps `p`'s cursor on its block, where the float can show it, and notes
-- whether it's on the last line.
local function keep_cursor(p: Peek)
	local from, to = log.range(p.block)
	if from == nil or to == nil or not p.view:valid() then
		return
	end
	local last = math.max(to - 1, from)
	local cursor = p.view:cursor()
	if cursor < from or cursor >= to then
		cursor = math.clamp(cursor, from, last)
		p.view:set_cursor(cursor)
	end
	local buffer = p.shell.buffer
	p.tail = buffer:line_of(cursor) == buffer:line_of(last)
end

-- Fits `p`'s float to its block, showing none of the shell around it, and
-- scrolls its view back to the block's command when it moved.
local function fit(p: Peek)
	local from, to = log.range(p.block)
	if from == nil or to == nil or not p.view:valid() then
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
	if tall ~= p.height then
		p.view:configure({ height = tall })
		p.height = tall
	end
	if line ~= p.line then
		p.view:set_scroll(line)
	end
	p.line = line
end

--- How a peek opens: without taking focus (`focus = false`, as when the
--- mouse rests on a block), at screen row `y`, and with `tail` on the
--- block's last line, following it as it grows.
export type How = { focus: boolean?, y: number?, tail: boolean? }

--- Opens a float at `block` of `shell`, with the cursor on its first line
--- of output (or its last, with `tail`), in place of a peek open already.
function M.open(shell: Shell, block: Block, how: How?): greed.View?
	M.close()
	local from = log.range(block)
	local tall = height(shell, block)
	if from == nil or tall == 0 then
		return nil
	end
	local focus = how == nil or how.focus ~= false
	local view = greed.float(shell.buffer, {
		title = string.match(block.command, "^[^\n]*") or block.command,
		width = "90%",
		height = tall,
		focus = focus,
		y = how and how.y,
		footer = "/ filter · enter or space . on a row · ctrl-c stops · esc closes",
	})
	view:set_cursor(log.output_range(shell, block) or from)
	local p: Peek = {
		view = view,
		shell = shell,
		block = block,
		line = -1,
		height = tall,
		tail = how ~= nil and how.tail == true,
	}
	open = p
	fit(p)
	if focus then
		greed.mode.set(core.style.home())
	end
	return view
end

--- After `block` shows something new: a peek at it grows or shrinks with
--- it, and scrolls back to it when what's above it moved it. Once the
--- block is gone, its peek closes.
function M.follow(block: Block)
	local p = open
	if p and p.block == block then
		if log.range(block) == nil then
			M.close()
		else
			fit(p)
		end
	end
end

log.on_update(M.follow)

greed.on("selection.changed", function(event: greed.SelectionChanged)
	local p = open
	if p and p.view == event.view then
		keep_cursor(p)
	end
end)

return M

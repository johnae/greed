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

type Peek = { view: greed.View, shell: Shell, block: Block, line: number, height: number }

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

-- Fits `p`'s float to its block, and scrolls its view back to the block's
-- command when it moved.
local function fit(p: Peek)
	local from = log.range(p.block)
	if from == nil or not p.view:valid() then
		return
	end
	local line = p.shell.buffer:line_of(from)
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

--- Opens a float at `block` of `shell`, with the cursor on its first line
--- of output, in place of a peek open already.
function M.open(shell: Shell, block: Block): greed.View?
	M.close()
	local from = log.range(block)
	local tall = height(shell, block)
	if from == nil or tall == 0 then
		return nil
	end
	local view = greed.float(shell.buffer, {
		title = string.match(block.command, "^[^\n]*") or block.command,
		width = "90%",
		height = tall,
		footer = "/ filter · enter or space . on a row · ctrl-c stops · esc closes",
	})
	view:set_cursor(log.output_range(shell, block) or from)
	local p: Peek = { view = view, shell = shell, block = block, line = -1, height = tall }
	open = p
	fit(p)
	greed.mode.set(core.style.home())
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

return M

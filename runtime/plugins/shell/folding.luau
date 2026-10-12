-- Folding blocks, besides `tab` and `shift-tab` (core.folds, with the
-- shell's blocks as what folds): `shell-fold-lines` folds a long block as it
-- ends, `shell-fold-older` folds the finished blocks above when a command
-- runs, `shell-fold-structured` folds long JSON or YAML at its keys as it
-- ends, and the mouse resting on a folded block peeks at it in a float that
-- leaves the cursor where it is. A folded block that's still printing stays
-- folded: `log.draw_block` stretches its fold as it grows. Blocks that failed
-- never fold by themselves, since they're the ones to read again.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local run = require("./run")
local peek = require("./peek")

type Shell = state.Shell
type Block = state.Block

local M = {}

greed.option.define({
	name = "shell-fold-lines",
	doc = "A block that printed more lines than this folds as it ends, unless it failed; 0 never",
	default = 0,
})

greed.option.define({
	name = "shell-fold-older",
	doc = "Running a command folds the finished blocks above it, except those that failed",
	default = false,
})

-- How long the mouse rests on a folded block before it peeks, in ms.
local REST = 400

-- Folds `block`, if it isn't folded and has more than its command line.
local function fold(shell: Shell, block: Block)
	local from = log.range(block)
	if from == nil then
		return
	end
	local buffer = shell.buffer
	local first, last = log.fold(shell, buffer:line_of(from))
	if first and not core.folds.starts(buffer, first) then
		core.folds.fold(buffer, first, last)
	end
end

greed.option.define({
	name = "shell-fold-structured",
	doc = "JSON or YAML output of more lines than this shows its top keys folded as it ends, and inside a fold still this long, the keys under it; 0 never",
	default = 100,
})

-- Whether lines `first` to `last` of `buffer` read as YAML or indented
-- JSON: most of them a key (`name:`, `"name":`) or a list item.
local function structured(buffer: greed.Buffer, first: number, last: number): boolean
	local keyed, all = 0, 0
	for line = first, math.min(last, first + 200) do
		local text = buffer:line_text(line)
		if string.find(text, "%S") then
			all += 1
			if
				string.find(text, "^%s*%- ")
				or string.find(text, '^%s*"?[%w_%.%-/]+"?:%s')
				or string.find(text, '^%s*"?[%w_%.%-/]+"?:$')
				or string.find(text, "^%s*[%]}{%[],?$")
			then
				keyed += 1
			end
		end
	end
	return all > 0 and keyed / all >= 0.6
end

-- Folds the sections of lines `top` to `bottom` at their outermost keys,
-- and inside one longer than `most` lines, the keys under it. A section
-- that's all there is, like JSON's outer braces, is gone into instead.
local function fold_keys(buffer: greed.Buffer, top: number, bottom: number, most: number)
	local least: number? = nil
	for line = top, bottom do
		local at = core.folds.indent(buffer, line, true)
		if at and (least == nil or at < least) then
			least = at
		end
	end
	local sections: { { number } } = {}
	for line = top, bottom do
		if core.folds.indent(buffer, line, true) == least then
			local first, last = core.folds.indented(buffer, line, top, bottom, true)
			if first == line then
				table.insert(sections, { line, last })
			end
		end
	end
	if #sections == 1 then
		fold_keys(buffer, sections[1][1] + 1, sections[1][2], most)
		return
	end
	for _, section in sections do
		local first, last = section[1], section[2]
		if last - first >= 2 and not core.folds.starts(buffer, first) then
			core.folds.fold(buffer, first, last)
			if last - first > most then
				fold_keys(buffer, first + 1, last, most)
			end
		end
	end
end

run.on_finish(function(shell: Shell, block: Block)
	local most = greed.option.get("shell-fold-lines") :: number
	if most > 0 and block.status == "done" and block.lines > most then
		fold(shell, block)
		return
	end
	local long = greed.option.get("shell-fold-structured") :: number
	local from, to = log.output_range(shell, block)
	if long <= 0 or block.status ~= "done" or block.lines <= long or from == nil or to == nil then
		return
	end
	local buffer = shell.buffer
	local first, last = buffer:line_of(from), buffer:line_of(to)
	if block.value ~= nil or structured(buffer, first, last) then
		fold_keys(buffer, first, last, long)
		-- Shorter now, it shows from its command where a view had scrolled
		-- past it following the output.
		local command = buffer:line_of(assert((log.range(block))))
		for _, view in buffer:views() do
			if view:scroll() > command then
				view:set_scroll(command)
			end
		end
	end
end)

--- Folds the finished blocks of `shell` other than `newest`, the one just
--- started, when `shell-fold-older` is on.
function M.fold_older(shell: Shell, newest: Block)
	if not greed.option.get("shell-fold-older") then
		return
	end
	for _, block in shell.blocks do
		if block ~= newest and block.status == "done" then
			fold(shell, block)
		end
	end
end

-- The folded block whose command line `pos` is on in `shell`, if any.
local function folded_at(shell: Shell, pos: number): Block?
	local block = log.block_at(shell, pos)
	local from = block and log.range(block)
	if block == nil or from == nil then
		return nil
	end
	local buffer = shell.buffer
	local line = buffer:line_of(from)
	if buffer:line_of(pos) ~= line or not core.folds.starts(buffer, line) then
		return nil
	end
	return block
end

-- What the mouse rests on now, and the peek resting opened.
local resting: { block: Block }? = nil
local hovered: greed.View? = nil

-- Closes the peek the mouse opened, unless it was clicked into since.
local function close_hovered()
	local view = hovered
	hovered = nil
	if view and view:valid() and greed.view() ~= view and peek.of(view) then
		peek.close()
	end
end

greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind ~= "move" then
		return
	end
	local view = event.view
	if view and view == hovered then
		return
	end
	local shell = if view then state.of(view:buffer()) else nil
	local pos = event.pos
	local block = if shell and pos then folded_at(shell, pos) else nil
	if shell == nil or block == nil then
		resting = nil
		close_hovered()
		return
	end
	if resting and resting.block == block then
		return
	end
	local mine = { block = block }
	resting = mine
	local row = event.row
	greed.spawn(function()
		greed.sleep(REST)
		if resting == mine then
			hovered = peek.open(shell, block, { focus = false, y = row + 1 })
		end
	end)
end)

return M

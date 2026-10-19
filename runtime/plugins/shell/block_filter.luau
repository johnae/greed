-- Filtering and sorting what a block shows: `/` on a block's lines or a
-- table's rows, in the shell, a float or a pane, and `space s` on a column.

local greed = require("@greed")
local state = require("./state")
local log = require("./log")
local peek = require("./peek")
local rows = require("./rows")
local filtering = require("./filtering")
local navigate = require("./navigate")
local query = require("./query")

type Shell = state.Shell
type Block = state.Block

-- The finished or live block whose output holds the cursor, if any; for a
-- block a filter shows nothing of, its command line too.
local function output_block(view: greed.View): (Shell?, Block?)
	local shell = state.of(view:buffer())
	local pos = view:cursor()
	local block = shell and log.block_at(shell, pos)
	if shell == nil or block == nil or (block.status == "running" and block.watching == nil) then
		return nil, nil
	end
	local from, to = log.output_range(shell, block)
	local inside = from ~= nil and to ~= nil and pos >= from and pos <= to
	if not inside and block.shown == nil then
		return nil, nil
	end
	return shell, block
end

-- Puts the cursor of `view` on `block`'s first line of output, where a
-- table's header is, or its command when a filter shows none of it, so
-- it stays in the block as what it shows changes.
local function to_output(shell: Shell, block: Block, view: greed.View)
	local from = log.output_range(shell, block) or log.range(block)
	if from then
		view:set_cursor(from)
	end
end

-- How many of the lines `view`, narrowed to a block, shows past its first
-- `skip` the filter `pattern` keeps, read as `opts` say, as "12 of 340
-- lines": what it matches, without the line the cursor keeps in sight.
local function kept_in(
	view: greed.View,
	skip: number,
	pattern: string,
	opts: { [string]: any }
): string?
	local first, last = view:narrowed()
	if first == nil or last == nil then
		return nil
	end
	local from = first + skip
	local ok, kept = pcall(function()
		local asked = table.clone(opts)
		asked.from, asked.to = from, last
		return view:buffer():kept_lines(pattern, asked)
	end)
	return if ok then `{#kept} of {last - from + 1} lines` else nil
end

-- Filters what `view`, showing `block` in a float or a pane, shows of it as
-- what's typed says (see query.luau): a query, or starting with `/` a
-- regex. Its command, and a table's header, stay.
local function filter_view(view: greed.View, block: Block)
	local skip = if block.table and block.table.header ~= false then 2 else 1
	local pattern = view:filter() or ""
	local opts: { [string]: any } = query.options(query.read(pattern)) or {}
	local function set(text: string)
		local filter = query.read(text)
		-- Half a regex or a quote, as it's typed, filters nothing yet.
		local read = query.options(filter)
		if read == nil then
			return
		end
		pattern, opts = filter.regex or text, read
		pcall(function()
			local asked = table.clone(opts)
			asked.skip = skip
			view:set_filter(pattern, asked)
		end)
	end
	filtering.prompt(block, {
		title = "Filter what this shows (/ for a regex)",
		text = view:filter() or "",
		on_change = set,
		on_submit = set,
		on_cancel = function()
			view:set_filter(nil)
		end,
		kept = function(): string?
			return if view:filter() then kept_in(view, skip, pattern, opts) else nil
		end,
	})
end

greed.command({
	name = "shell-filter",
	doc = "Keep the lines of the block at the cursor with what's typed in them (/ for a regex), or a table's rows (COL=VALUE, COL~TEXT, COL>N); elsewhere, search",
	run = function(ctx)
		local view = ctx.view
		-- On a line of the strip, it works on the block in a float.
		local here = state.of(ctx.buffer)
		local stripped = here and log.strip_block(here, view:cursor())
		if here and stripped then
			view = peek.open(here, stripped) or view
		end
		-- One still printing, like followed logs, is filtered in a float of
		-- its own, where what it shows next is filtered too.
		local at = here and log.block_at(here, view:cursor())
		if here and at and at.status == "running" and at.watching == nil and not peek.of(view) then
			view = peek.open(here, at) or view
		end
		-- A float or a pane showing a block filters what it shows alone: the
		-- block keeps every line, and the shell shows them all.
		local own = peek.of(view)
		if own then
			filter_view(view, own)
			return
		end
		local shell, block = output_block(view)
		if shell == nil or block == nil then
			greed.run("search")
			return
		end
		local shown = block.shown
		local sort, desc = if shown then shown.sort else nil, shown ~= nil and shown.desc
		-- From blocks mode, the command stays selected, with what it kept
		-- under it.
		local from_blocks = greed.mode.get() == navigate.MODE
		local function set(text: string)
			rows.set(shell, block, text, sort, desc)
			peek.follow(block)
			local command = log.range(block)
			if from_blocks and command then
				view:set_cursor(command)
			else
				to_output(shell, block, view)
			end
		end
		filtering.prompt(block, {
			title = if block.table then "Filter rows" else "Filter lines",
			text = if shown then shown.filter else "",
			on_change = set,
			on_submit = set,
			on_cancel = function()
				set("")
			end,
			kept = function(): string?
				local now = block.shown
				if now == nil or now.filter == "" then
					return nil
				end
				return `{#now.rows} of {now.total} {if block.table then "rows" else "lines"}`
			end,
		})
	end,
})

greed.command({
	name = "shell-sort",
	doc = "Sort the table at the cursor by the column under it; again to reverse, a third time as it came",
	run = function(ctx)
		local shell, block = output_block(ctx.view)
		local pos = ctx.view:cursor()
		local column = shell and block and rows.column_at(shell, block, pos)
		if shell == nil or block == nil or column == nil then
			greed.echo("put the cursor on a column of a table, like kubectl get pods prints")
			return
		end
		local col = ctx.buffer:display_column(pos)
		rows.sort(shell, block, column)
		peek.follow(block)
		-- The cursor stays in the column, on the header.
		local from = log.output_range(shell, block)
		if from then
			ctx.view:set_cursor(ctx.buffer:at_display_column(ctx.buffer:line_of(from), col))
		end
	end,
})

greed.command({
	name = "shell-unfilter",
	doc = "Show every line, or row, of the filtered block at the cursor again, keeping its sort; in a block's float, close it",
	run = function(ctx)
		if peek.of(ctx.view) then
			peek.close(ctx.view)
			return
		end
		local shell, block = output_block(ctx.view)
		local shown = block and block.shown
		if shell and block and shown and shown.filter ~= "" then
			rows.set(shell, block, "", shown.sort, shown.desc)
			peek.follow(block)
			to_output(shell, block, ctx.view)
		end
	end,
})

greed.command({
	name = "shell-show-all",
	doc = "Show the block at the cursor's output as it came, without a filter or a sort",
	run = function(ctx)
		local shell, block = output_block(ctx.view)
		if shell and block then
			rows.reset(shell, block)
			peek.follow(block)
		end
	end,
})

return {}

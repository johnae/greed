-- A data block's table opened in a float as text, to go through with the
-- keyboard: the table under a block is drawn, not text, so the cursor
-- can't go into it. Here it's text, so search, copy and every motion work
-- on it; `enter` on a row shows the whole record, the buttons under it
-- turn the page or read it again, and `q` closes it. Drawn with
-- `core.ui`.

local greed = require("@greed")
local core = require("@core")
local document = require("./document")

local ui = core.ui

local M = {}

-- How many rows a page shows when the block doesn't say (`rows=N`).
local PAGE = 50

local KIND = "data-table"

-- A row's record, opened from the table.
local ROW = "data-row"

--- Opens the data block `code` of `buffer` in a float, reading its table
--- a page at a time.
function M.open(buffer: greed.Buffer, code: any)
	local source = core.data.get(code.lang)
	if source == nil then
		return
	end
	local ask = document.ask(buffer, code)
	local limit = ask.limit or PAGE
	ask.limit = limit
	ask.offset = 0
	local float_buffer = greed.create_buffer(KIND, "", { readonly = true })
	float_buffer:set_line_numbers(false)
	local what = ask.args.path or ask.args.db
	local title = if what then `{code.lang} · {what}` else code.lang
	local table_view = greed.float(float_buffer, { title = title, width = "90%", height = "70%" })
	local view: core.UiView
	local function read()
		view:set({ status = "reading" })
		greed.spawn(function()
			local t, why = core.data.read(source.name, ask)
			view:set({ table = t, why = why, status = if t then "read" else "failed" })
		end)
	end
	local function turn(by: number)
		ask.offset = math.max((ask.offset or 0) + by * limit, 0)
		read()
	end
	-- A row's record, with what the source can do with it as buttons;
	-- doing one that leaves the table open reads it again.
	local function show_row(t: core.DataTable, row: { [string]: any })
		local lines: { string } = {}
		for _, column in t.columns do
			table.insert(lines, `{column.name}: {core.data.show(row[column.name])}`)
		end
		local actions: { core.DataAction } = source.actions or {}
		if #actions == 0 then
			core.floats.show_text("Row", table.concat(lines, "\n"), { kind = ROW })
			return
		end
		local record = greed.create_buffer(ROW, "", { readonly = true })
		record:set_line_numbers(false)
		local shown = greed.float(record, { title = "Row", width = "60%", height = "40%" })
		ui.mount(record, function()
			local parts: { core.UiNode } = {}
			for _, line in lines do
				table.insert(parts, ui.text(line))
			end
			local buttons: { core.UiNode } = {}
			for _, action in actions do
				table.insert(
					buttons,
					ui.button(action.name, function()
						greed.spawn(function()
							if shown:valid() then
								shown:close()
							end
							if action.close and table_view:valid() then
								table_view:close()
							end
							local ok, said = pcall(action.run, row)
							if not ok or said then
								greed.echo(tostring(said))
							end
							if not action.close then
								read()
							end
						end)
					end)
				)
			end
			table.insert(parts, ui.gap())
			table.insert(parts, ui.row(buttons, { gap = 2, fit = true }))
			return ui.column(parts)
		end, {})
	end
	view = ui.mount(float_buffer, function(state)
		local parts: { core.UiNode } = {}
		local t: core.DataTable? = state.table
		if state.status == "failed" then
			table.insert(
				parts,
				ui.line({ ui.span(`⚠ {state.why or "it failed"}`, "markdown.value.error") })
			)
		elseif t then
			local from = (ask.offset or 0) + 1
			local through = from + #t.rows - 1
			table.insert(
				parts,
				ui.line({
					ui.span(
						if #t.rows == 0 then "no rows" else `rows {from}–{through}`,
						"markdown.marker"
					),
				})
			)
			table.insert(
				parts,
				document.node(t, function(row: { [string]: any })
					show_row(t, row)
				end)
			)
		else
			table.insert(parts, ui.line({ ui.span("reading…", "markdown.marker") }))
		end
		local buttons: { core.UiNode } = {}
		if (ask.offset or 0) > 0 then
			table.insert(
				buttons,
				ui.button("◀ Earlier", function()
					turn(-1)
				end)
			)
		end
		if t and t.more then
			table.insert(
				buttons,
				ui.button("Later ▶", function()
					turn(1)
				end)
			)
		end
		table.insert(buttons, ui.button("Read again", read))
		table.insert(parts, ui.gap())
		table.insert(parts, ui.row(buttons, { gap = 2, fit = true }))
		return ui.column(parts)
	end, { status = "reading" })
	read()
end

greed.command({
	name = "data-open",
	doc = "Open the data block at the cursor's table in a float, as text to go through",
	run = function(ctx)
		local code, entry = document.at(ctx.buffer, ctx.view:cursor())
		if code == nil then
			greed.echo("there's no data block here")
		elseif entry and entry.status == "waiting" then
			greed.echo("it hasn't been let run: enter on its first line")
		else
			M.open(ctx.buffer, code)
		end
	end,
})

greed.command({
	name = "data-close",
	doc = "Close the float showing a data block's table, or a row of it",
	run = function(ctx)
		local kind = ctx.buffer:kind()
		if kind == KIND or kind == ROW then
			ctx.view:close()
		end
	end,
})

greed.keymap.bind({ kind = KIND }, { q = "data-close", esc = "data-close" })
greed.keymap.bind({ kind = ROW }, { q = "data-close", esc = "data-close" })

return M

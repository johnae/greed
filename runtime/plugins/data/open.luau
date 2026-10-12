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
	greed.float(float_buffer, { title = title, width = "90%", height = "70%" })
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
					local lines: { string } = {}
					for _, column in t.columns do
						table.insert(lines, `{column.name}: {core.data.show(row[column.name])}`)
					end
					core.floats.show_text("Row", table.concat(lines, "\n"), { kind = "data-row" })
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
	doc = "Close the float showing a data block's table",
	run = function(ctx)
		if ctx.buffer:kind() == KIND then
			ctx.view:close()
		end
	end,
})

greed.keymap.bind({ kind = KIND }, { q = "data-close", esc = "data-close" })

return M

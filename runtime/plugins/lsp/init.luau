-- Language servers: hover, definitions, references, rename, code actions
-- and diagnostics. Lines with problems get a sign, and the worst problem's
-- message shows after the line (turn that off with
-- `:set diagnostic-messages false`).
--
--   space k   show what's under the cursor, with any problems there
--   g d       go to the definition
--   g r       pick a place it's used
--   space r   rename it everywhere
--   space a   pick a fix or refactor
--   space d   pick a problem in this file
--   space D   pick a problem in any file
--   ] d / [ d next / previous problem
--
-- Servers start the first time a file of their language is open, if one is
-- installed; the languages plugin says which (see `:health`).

local kern = require("@kern")
local picker = require("@picker")
local common = require("@self/common")
local marks = require("@self/marks")
require("@self/completion")
require("@self/edits")
require("@self/places")
require("@self/actions")
require("@self/signature")

local head, move_to, ask, describe = common.head, common.move_to, common.ask, common.describe

-- Hover contents come as a string, a { value } table, or a list of those.
local function hover_text(contents: any): string
	if type(contents) == "string" then
		return contents
	elseif type(contents) == "table" and contents.value then
		return contents.value
	elseif type(contents) == "table" then
		local parts = {}
		for _, part in contents do
			table.insert(parts, hover_text(part))
		end
		return table.concat(parts, "\n\n")
	end
	return ""
end

-- Drops Markdown code fence lines ("```rust", "```"), which servers wrap
-- code in.
local function without_fences(text: string): string
	local kept = {}
	for _, line in string.split(text, "\n") do
		if not string.match(line, "^```") then
			table.insert(kept, line)
		end
	end
	return table.concat(kept, "\n")
end

local shown: kern.View? = nil

local function close_info()
	if shown then
		shown:close()
		shown = nil
	end
end

local function show_info(title: string, text: string)
	close_info()
	local lines = string.split(text, "\n")
	local buffer = kern.create_buffer("info", text)
	shown = kern.float(buffer, { title = title, width = "70%", height = math.min(#lines + 2, 20) })
end

kern.command({
	name = "hover",
	doc = "Show what's under the cursor, and any problems there",
	run = function(ctx)
		local pos = head(ctx.view)
		local parts = {}
		for _, d in kern.lsp.diagnostics(ctx.buffer) do
			if d.from <= pos and pos <= d.to then
				table.insert(parts, describe(d))
			end
		end
		local ok, result = ask(ctx.buffer, "textDocument/hover", pos)
		if not ok and #parts == 0 then
			return
		end
		local text = if result and result.contents
			then without_fences(hover_text(result.contents))
			else ""
		if string.match(text, "%S") then
			table.insert(parts, text)
		end
		if #parts == 0 then
			kern.echo("nothing to show here")
			return
		end
		show_info("Hover", table.concat(parts, "\n\n"))
	end,
})

kern.command({
	name = "goto-definition",
	doc = "Go to where the thing under the cursor is defined",
	run = function(ctx)
		local ok, result, err = ask(ctx.buffer, "textDocument/definition", head(ctx.view))
		if not ok then
			return
		elseif err then
			kern.echo(`definition: {err.message}`)
			return
		end
		-- A location, a list of locations or links (maybe empty), or nothing.
		local target = if result and result[1] then result[1] else result
		if target == nil or (target.uri == nil and target.targetUri == nil) then
			kern.echo("no definition found")
			return
		end
		local uri = target.uri or target.targetUri
		local range = target.range or target.targetSelectionRange
		local path = kern.lsp.path(uri)
		if path == nil then
			kern.echo(`can't open {uri}`)
			return
		end
		common.open_at(path, range.start)
	end,
})

local function sorted_diagnostics(buffer: kern.Buffer): { kern.Diagnostic }
	local list = kern.lsp.diagnostics(buffer)
	table.sort(list, function(a: kern.Diagnostic, b: kern.Diagnostic)
		return a.from < b.from
	end)
	return list
end

local function jump(ctx: kern.Context, forward: boolean)
	local pos = head(ctx.view)
	local list = sorted_diagnostics(ctx.buffer)
	local target = nil
	if forward then
		for _, d in list do
			if d.from > pos then
				target = d
				break
			end
		end
	else
		for i = #list, 1, -1 do
			if list[i].from < pos then
				target = list[i]
				break
			end
		end
	end
	if target then
		move_to(ctx.view, target.from)
		kern.echo(describe(target))
	else
		kern.echo("no more problems")
	end
end

kern.command({
	name = "next-diagnostic",
	doc = "Go to the next problem in this file",
	run = function(ctx)
		jump(ctx, true)
	end,
})

kern.command({
	name = "prev-diagnostic",
	doc = "Go to the previous problem in this file",
	run = function(ctx)
		jump(ctx, false)
	end,
})

kern.command({
	name = "pick-diagnostic",
	doc = "Pick a problem in this file and go to it",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local items = {}
		for _, d in sorted_diagnostics(buffer) do
			local line = buffer:line_of(d.from) + 1
			table.insert(items, { label = `{line}: {describe(d)}`, value = d.from })
		end
		if #items == 0 then
			kern.echo("no problems")
			return
		end
		local text, language = buffer:text(), buffer:language()
		picker.pick("Problems", items, function(item)
			move_to(view, item.value)
		end, {
			preview = function(item)
				return { text = text, language = language, line = buffer:line_of(item.value) }
			end,
		})
	end,
})

kern.command({
	name = "info-close",
	doc = "Close the hover window",
	run = close_info,
})

-- A server asking you to pick, e.g. "Reload the project?" with buttons:
-- the actions show in a picker titled with its message, and the server
-- hears which one you chose, or nothing if you closed it.
kern.lsp.on_request("window/showMessageRequest", function(params)
	local actions = params.actions or {}
	if #actions == 0 then
		kern.echo(params.message)
		return nil
	end
	local items = {}
	for _, action in actions do
		table.insert(items, { label = action.title, value = action })
	end
	local item = picker.choose(params.message, items)
	return if item then item.value else nil
end)

kern.keymap.bind({ mode = "normal", kind = "info" }, { esc = "info-close", q = "info-close" })
kern.keymap.bind("normal", {
	["space k"] = "hover",
	["g d"] = "goto-definition",
	["space d"] = "pick-diagnostic",
	["] d"] = "next-diagnostic",
	["[ d"] = "prev-diagnostic",
})

kern.option.define({
	name = "diagnostic-messages",
	doc = "Show each line's worst problem after the end of the line",
	default = true,
})

-- Signs beside lines with problems, and their messages after the line.
local function mark_problems(buffer: kern.Buffer)
	local messages = kern.option.get("diagnostic-messages") == true
	buffer:decorate("lsp", marks.diagnostic_marks(buffer, kern.lsp.diagnostics(buffer), messages))
end

kern.on("lsp.diagnostics", function(event: kern.DiagnosticsChanged)
	mark_problems(event.buffer)
end)

kern.on("option.changed", function(event)
	if event.name == "diagnostic-messages" then
		for _, buffer in kern.buffers() do
			mark_problems(buffer)
		end
	end
end)

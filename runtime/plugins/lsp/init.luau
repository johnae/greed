-- Language servers: hover, go to definition and diagnostics. Lines with
-- problems get a sign, and the worst problem's message shows after the line
-- (turn that off with `:set diagnostic-messages false`).
--
--   space k   show what's under the cursor, with any problems there
--   g d       go to the definition
--   space d   pick a problem in this file
--   ] d / [ d next / previous problem
--
-- Servers start the first time a file of their language is open, if one is
-- installed; the languages plugin says which (see `:health`).

local kern = require("@kern")
local picker = require("@picker")
local marks = require("@self/marks")

local function head(view: kern.View): number
	local selection = view:selection()
	return selection.ranges[selection.primary].head
end

local function move_to(view: kern.View, pos: number)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

-- Parameters for requests about the position at `pos`.
local function at(buffer: kern.Buffer, pos: number)
	return {
		textDocument = { uri = kern.lsp.uri(buffer) },
		position = kern.lsp.position(buffer, pos),
	}
end

-- Asks the buffer's server about the position at `pos`. Returns whether it got
-- an answer, then the result, or nil and the error. Without a server it
-- says so.
local function ask(buffer: kern.Buffer, method: string, pos: number): (boolean, any, any)
	if buffer:path() == nil then
		kern.echo("no language server for this buffer")
		return false
	end
	local ok, result, err = pcall(function()
		return kern.lsp.request(buffer, method, at(buffer, pos))
	end)
	if not ok then
		kern.echo(tostring(result))
		return false
	end
	return true, result, err
end

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

local SEVERITY = { "error", "warning", "info", "hint" }

local function describe(d: kern.Diagnostic): string
	return `{SEVERITY[d.severity] or "problem"}: {d.message}`
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
		kern.open(path)
		local view = kern.view()
		move_to(view, kern.lsp.offset(view:buffer(), range.start))
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

-- Language servers: hover, go to definition and diagnostics.
--
--   space k   show what's under the cursor, with any problems there
--   g d       go to the definition
--   space d   pick a problem in this file
--   ] d / [ d next / previous problem
--
-- Servers start the first time a file of their language is open. Change
-- them from your config with `kern.lsp.server`.

local kern = require("@kern")
local picker = require("@picker")

kern.lsp.server({ language = "rust", command = { "rust-analyzer" }, root_markers = { "Cargo.toml" } })
kern.lsp.server({ language = "luau", command = { "luau-lsp", "lsp" }, root_markers = { ".luaurc" } })
kern.lsp.server({ language = "markdown", command = { "harper-ls", "--stdio" } })

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
		local result = kern.lsp.request(ctx.buffer, "textDocument/hover", at(ctx.buffer, pos))
		if result and result.contents then
			table.insert(parts, without_fences(hover_text(result.contents)))
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
		local result, err = kern.lsp.request(ctx.buffer, "textDocument/definition", at(ctx.buffer, head(ctx.view)))
		if err then
			kern.echo(`definition: {err.message}`)
			return
		end
		-- A location, a list of locations, or a list of links.
		local target = if result and result[1] then result[1] else result
		if target == nil then
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
		picker.pick("Problems", items, function(item)
			move_to(view, item.value)
		end)
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

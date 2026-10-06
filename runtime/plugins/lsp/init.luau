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

local greed = require("@greed")
local picker = require("@picker")
local common = require("@self/common")
local marks = require("@self/marks")
require("@self/completion")
require("@self/edits")
require("@self/places")
require("@self/actions")
require("@self/signature")
local status = require("@self/status")

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

local shown: greed.View? = nil

local function close_info()
	if shown then
		shown:close()
		shown = nil
	end
end

local function show_info(title: string, text: string)
	close_info()
	local lines = string.split(text, "\n")
	local buffer = greed.create_buffer("info", text)
	shown = greed.float(buffer, { title = title, width = "70%", height = math.min(#lines + 2, 20) })
end

greed.command({
	name = "hover",
	doc = "Show what's under the cursor, and any problems there",
	run = function(ctx)
		local pos = head(ctx.view)
		local parts = {}
		for _, d in greed.lsp.diagnostics(ctx.buffer) do
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
			greed.echo("nothing to show here")
			return
		end
		show_info("Hover", table.concat(parts, "\n\n"))
	end,
})

-- Commands that go to where the language server says something under the
-- cursor is: its definition, declaration, type or implementation.
for _, place in
	{
		{ "goto-definition", "definition", "defined" },
		{ "goto-declaration", "declaration", "declared" },
		{ "goto-type-definition", "typeDefinition", "its type is defined" },
		{ "goto-implementation", "implementation", "implemented" },
	}
do
	local name, method, what = place[1], place[2], place[3]
	greed.command({
		name = name,
		doc = `Go to where the thing under the cursor is {what}`,
		run = function(ctx)
			local ok, result, err = ask(ctx.buffer, `textDocument/{method}`, head(ctx.view))
			if not ok then
				return
			elseif err then
				greed.echo(`{method}: {err.message}`)
				return
			end
			-- A location, a list of locations or links (maybe empty), or nothing.
			local target = if result and result[1] then result[1] else result
			if target == nil or (target.uri == nil and target.targetUri == nil) then
				greed.echo(`no {method} found`)
				return
			end
			local uri = target.uri or target.targetUri
			local range = target.range or target.targetSelectionRange
			local path = greed.lsp.path(uri)
			if path == nil then
				greed.echo(`can't open {uri}`)
				return
			end
			common.open_at(path, range.start)
		end,
	})
end

local function sorted_diagnostics(buffer: greed.Buffer): { greed.Diagnostic }
	local list = greed.lsp.diagnostics(buffer)
	table.sort(list, function(a: greed.Diagnostic, b: greed.Diagnostic)
		return a.from < b.from
	end)
	return list
end

local function jump(ctx: greed.Context, forward: boolean)
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
		greed.echo(describe(target))
	else
		greed.echo("no more problems")
	end
end

greed.command({
	name = "next-diagnostic",
	doc = "Go to the next problem in this file",
	run = function(ctx)
		jump(ctx, true)
	end,
})

greed.command({
	name = "prev-diagnostic",
	doc = "Go to the previous problem in this file",
	run = function(ctx)
		jump(ctx, false)
	end,
})

for _, last in { false, true } do
	greed.command({
		name = if last then "last-diagnostic" else "first-diagnostic",
		doc = if last
			then "Go to the last problem in this file"
			else "Go to the first problem in this file",
		run = function(ctx)
			local list = sorted_diagnostics(ctx.buffer)
			local target = list[if last then #list else 1]
			if target then
				move_to(ctx.view, target.from)
				greed.echo(describe(target))
			else
				greed.echo("no problems")
			end
		end,
	})
end

greed.command({
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
			greed.echo("no problems")
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

greed.command({
	name = "info-close",
	doc = "Close the hover window",
	run = close_info,
})

-- A server asking you to pick, e.g. "Reload the project?" with buttons:
-- the actions show in a picker titled with its message, and the server
-- hears which one you chose, or nothing if you closed it.
greed.lsp.on_request("window/showMessageRequest", function(params)
	local actions = params.actions or {}
	if #actions == 0 then
		greed.echo(params.message)
		return nil
	end
	local items = {}
	for _, action in actions do
		table.insert(items, { label = action.title, value = action })
	end
	local item = picker.choose(params.message, items)
	return if item then item.value else nil
end)

greed.keymap.bind({ mode = "normal", kind = "info" }, { esc = "info-close", q = "info-close" })
greed.keymap.bind("normal", {
	["space k"] = "hover",
	["g d"] = "goto-definition",
	["g D"] = "goto-declaration",
	["g y"] = "goto-type-definition",
	["g i"] = "goto-implementation",
	["space d"] = "pick-diagnostic",
	["] d"] = "next-diagnostic",
	["[ d"] = "prev-diagnostic",
	["] D"] = "last-diagnostic",
	["[ D"] = "first-diagnostic",
})

greed.option.define({
	name = "diagnostic-messages",
	doc = "Show each line's worst problem after the end of the line",
	default = true,
})

-- Signs beside lines with problems, and their messages after the line.
local function mark_problems(buffer: greed.Buffer)
	local messages = greed.option.get("diagnostic-messages") == true
	buffer:decorate("lsp", marks.diagnostic_marks(buffer, greed.lsp.diagnostics(buffer), messages))
end

greed.on("lsp.diagnostics", function(event: greed.DiagnosticsChanged)
	mark_problems(event.buffer)
end)

greed.on("option.changed", function(event)
	if event.name == "diagnostic-messages" then
		for _, buffer in greed.buffers() do
			mark_problems(buffer)
		end
	end
end)

-- Symbols and problems, as things to act on.
local actions = require("@core").actions

actions.finder({
	name = "symbol",
	find = function(view, range)
		local buffer = view:buffer()
		if greed.lsp.capabilities(buffer) == nil then
			return nil
		end
		local line = buffer:line_of(range.head)
		local start = buffer:line_start(line)
		local text = buffer:slice(start, buffer:line_end(line))
		local at = range.head - start + 1
		local init = 1
		while true do
			local from, to = string.find(text, "[%w_]+", init)
			if from == nil or to == nil or from > at then
				return nil
			end
			if at <= to then
				local name = string.sub(text, from, to)
				return {
					{
						kind = "symbol",
						label = name,
						value = name,
						from = start + from - 1,
						to = start + to,
					},
				}
			end
			init = to + 1
		end
	end,
})

actions.command("symbol", "definition", "goto-definition", "Go to where it's defined")
actions.command("symbol", "references", "goto-references", "Find everywhere it's used")
actions.command("symbol", "rename", "rename", "Rename it everywhere")
actions.command("symbol", "hover", "hover", "Show its type and docs")
actions.command(
	"symbol",
	"code-action",
	"code-action",
	"The language server's fixes and refactorings here"
)

actions.finder({
	name = "problem",
	find = function(view, range)
		local found = {}
		for _, d in greed.lsp.diagnostics(view:buffer()) do
			if d.from <= range.head and range.head <= d.to then
				local label = string.gsub(string.sub(d.message, 1, 60), "\n", " ")
				table.insert(
					found,
					{ kind = "problem", label = label, value = d.message, from = d.from, to = d.to }
				)
			end
		end
		return found
	end,
})

actions.command("problem", "fix", "code-action", "The language server's fixes for it")
actions.action({
	kind = "problem",
	name = "copy",
	doc = "Copy the message",
	run = function(target)
		greed.clipboard.set(target.value)
	end,
})

-- Other plugins can use these with `require("@lsp")`.
return {
	--- The language server piece of the status line, and the progress it shows.
	status = status,
}

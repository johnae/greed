-- Changes the language server works out, for agents: renaming a name
-- everywhere it's used, and the server's code actions (quick fixes,
-- refactors). The server's edits come to the user as proposals, one
-- operation each, so nothing changes until they accept.

local greed = require("@greed")
local core = require("@core")
local agent = require("./registry")
local proposals = require("./proposals")

local object = agent.schema.object

-- The file at `path` (relative to the project, or absolute), opened
-- without showing it if it isn't open.
local function load(path: string): greed.Buffer
	return greed.load(core.project.resolve(path))
end

-- Asks the buffer's server, failing with why when there's no server or it
-- says no.
local function request(buffer: greed.Buffer, method: string, params: any): any
	local ok, result, err = pcall(greed.lsp.request, buffer, method, params)
	if not ok then
		error(tostring(result), 0)
	elseif err then
		error(`the language server says: {err.message}`, 0)
	end
	return result
end

-- The byte range of 1-based `line` in `buffer`, checked.
local function line_range(buffer: greed.Buffer, line: number): (number, number)
	if line < 1 or line > buffer:line_count() then
		error(`{buffer:path()} has {buffer:line_count()} lines, there's no line {line}`, 0)
	end
	return buffer:line_start(line - 1), buffer:line_end(line - 1)
end

-- Where `name` starts as a whole word on 1-based `line`.
local function find_name(buffer: greed.Buffer, line: number, name: string): number
	local from, to = line_range(buffer, line)
	local escaped = string.gsub(name, "[%^%$%.%*%+%?%(%)%[%]{}|\\]", "\\%0")
	local pattern = "\\b" .. escaped .. "\\b"
	local found = (buffer:find_all(pattern, from, to) or {})[1]
	if found == nil then
		error(`{name} isn't on line {line} of {buffer:path()}`, 0)
	end
	return found.from
end

-- A workspace edit as proposals: the files it changes, each with its
-- changes as byte ranges. Only files in `project` may change, and only
-- their text: an edit creating, renaming or deleting files is refused.
local function changes_of(edit: any, project: string): { proposals.FileChanges }
	local per_file: { { uri: string, edits: { any } } } = {}
	if edit.documentChanges then
		-- A file listed twice is one file's edits.
		local edits_of: { [string]: { any } } = {}
		for _, change in edit.documentChanges do
			if change.kind then
				error(`the server's change would {change.kind} a file, which isn't supported`, 0)
			end
			local uri = change.textDocument.uri
			if edits_of[uri] == nil then
				edits_of[uri] = {}
				table.insert(per_file, { uri = uri, edits = edits_of[uri] })
			end
			for _, e in change.edits do
				table.insert(edits_of[uri], e)
			end
		end
	elseif edit.changes then
		for uri, edits in edit.changes do
			table.insert(per_file, { uri = uri, edits = edits })
		end
	end
	local root = project .. "/"
	local files: { proposals.FileChanges } = {}
	for _, file in per_file do
		local path = greed.lsp.path(file.uri)
		if path == nil or string.sub(path, 1, #root) ~= root then
			error(`the server's change touches {path or file.uri}, outside the project`, 0)
		end
		local buffer = greed.load(path)
		local changes: { proposals.Change } = {}
		for i, e in file.edits do
			local from = greed.lsp.offset(buffer, e.range.start)
			local to = greed.lsp.offset(buffer, e.range["end"])
			table.insert(changes, { from = from, to = to, text = e.newText, i = i } :: any)
		end
		-- In file order; edits at one place keep the server's order.
		table.sort(changes, function(a: any, b: any)
			return if a.from == b.from then a.i < b.i else a.from < b.from
		end)
		for n = 2, #changes do
			if changes[n].from < changes[n - 1].to then
				error(`the server's changes to {path} overlap`, 0)
			end
		end
		if #changes > 0 then
			table.insert(files, { buffer = buffer, path = path, changes = changes })
		end
	end
	return files
end

-- Proposes what `edit` changes, in `buffer`'s project, and waits for the
-- user.
local function propose(buffer: greed.Buffer, edit: any, reason: string): string
	local files = changes_of(edit, core.project.root(buffer:path()))
	if #files == 0 then
		return "the language server had nothing to change"
	end
	return proposals.propose_ranges(files, reason)
end

local LOCATION = {
	path = { type = "string" },
	line = { type = "integer", description = "1-based" },
}

agent.tool({
	name = "rename",
	kind = "edit",
	reviews = true,
	group = "refactor",
	description = "Rename a function, type, variable or other name everywhere it's used, as the "
		.. "language server works it out. Give the line it's on and the name as it is now. The "
		.. "changes go to the user to review as one operation; waits and says what they accepted",
	input = object({
		path = LOCATION.path,
		line = LOCATION.line,
		name = { type = "string", description = "The name as it is now, on that line" },
		new_name = { type = "string" },
		reason = { type = "string", description = "One line on why, shown to the user" },
	}, { "path", "line", "name", "new_name" }),
	run = function(args)
		local buffer = load(args.path)
		local at = find_name(buffer, args.line, args.name)
		local edit = request(buffer, "textDocument/rename", {
			textDocument = { uri = greed.lsp.uri(buffer) },
			position = greed.lsp.position(buffer, at),
			newName = args.new_name,
		})
		if edit == nil then
			return `the language server can't rename {args.name} there`
		end
		return propose(buffer, edit, args.reason or `rename {args.name} to {args.new_name}`)
	end,
})

-- The server's code actions for lines `line`..`to_line` of `buffer`, with
-- the problems reported there, which it may offer fixes for.
local function actions(buffer: greed.Buffer, line: number, to_line: number?): { any }
	local from = line_range(buffer, line)
	local _, to = line_range(buffer, to_line or line)
	local problems = {}
	for _, d in greed.lsp.diagnostics(buffer) do
		if d.from <= to and from <= d.to then
			table.insert(problems, {
				range = {
					start = greed.lsp.position(buffer, d.from),
					["end"] = greed.lsp.position(buffer, d.to),
				},
				severity = d.severity,
				message = d.message,
				source = d.source,
			})
		end
	end
	local result = request(buffer, "textDocument/codeAction", {
		textDocument = { uri = greed.lsp.uri(buffer) },
		range = {
			start = greed.lsp.position(buffer, from),
			["end"] = greed.lsp.position(buffer, to),
		},
		context = { diagnostics = greed.json.array(problems) },
	})
	local list = {}
	for _, action in result or {} do
		if not action.disabled then
			-- A bare command, the older kind of answer.
			if type(action.command) == "string" then
				action = { title = action.title, command = action }
			end
			table.insert(list, action)
		end
	end
	return list
end

local RANGE = {
	path = LOCATION.path,
	line = LOCATION.line,
	to_line = { type = "integer", description = "The last line, 1-based; default line" },
}

agent.tool({
	name = "code_actions",
	group = "refactor",
	description = "The language server's code actions (quick fixes for the problems there, "
		.. "refactors) for some lines of a file. Use code_action with one's title to propose it",
	input = object(RANGE, { "path", "line" }),
	run = function(args)
		local buffer = load(args.path)
		local lines = {}
		for _, action in actions(buffer, args.line, args.to_line) do
			local kind = if action.kind then ` ({action.kind})` else ""
			local preferred = if action.isPreferred then ", preferred" else ""
			table.insert(lines, `{action.title}{kind}{preferred}`)
		end
		if #lines == 0 then
			return "no code actions there"
		end
		return table.concat(lines, "\n")
	end,
})

agent.tool({
	name = "code_action",
	kind = "edit",
	reviews = true,
	group = "refactor",
	description = "Propose one of the language server's code actions for some lines, by its "
		.. "title as code_actions lists it. Its changes go to the user to review as one "
		.. "operation; waits and says what they accepted. Actions that run a command in the "
		.. "server can't be reviewed first, so they're refused",
	input = object({
		path = RANGE.path,
		line = RANGE.line,
		to_line = RANGE.to_line,
		title = { type = "string" },
		reason = { type = "string", description = "One line on why, shown to the user" },
	}, { "path", "line", "title" }),
	run = function(args)
		local buffer = load(args.path)
		local chosen: any
		for _, action in actions(buffer, args.line, args.to_line) do
			if action.title == args.title then
				chosen = action
				break
			end
		end
		if chosen == nil then
			error(`there's no code action called "{args.title}" there; code_actions lists them`, 0)
		end
		if chosen.edit == nil and chosen.command == nil and chosen.data ~= nil then
			chosen = request(buffer, "codeAction/resolve", chosen) or chosen
		end
		-- A command could change anything, out of sight, so only edits go.
		if chosen.command then
			error(
				`"{args.title}" runs a command in the language server, which can't be shown for `
					.. "review first; ask the user to run it with space a",
				0
			)
		end
		if chosen.edit == nil then
			return `"{args.title}" has no changes to make`
		end
		return propose(buffer, chosen.edit, args.reason or chosen.title)
	end,
})

return {}

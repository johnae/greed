-- The tools Kern offers agents out of the box. Each is also `kern ctl NAME`.

local kern = require("@kern")
local core = require("@core")
local agent = require("./registry")

local function object(properties: { [string]: any }, required: { string }?): { [string]: any }
	return { type = "object", properties = properties, required = required }
end

-- The open buffer for `path`, matching it as given, against the project,
-- or by its end; nil if it isn't open.
local function find_buffer(path: string): kern.Buffer?
	local cwd = kern.fs.cwd()
	for _, buffer in kern.buffers() do
		local own = buffer:path()
		if own and (own == path or cwd .. "/" .. own == path or own == cwd .. "/" .. path) then
			return buffer
		end
	end
	return nil
end

-- 1-based line and column, as people and agents count them.
local function position(buffer: kern.Buffer, pos: number): { line: number, column: number }
	local line = buffer:line_of(pos)
	return { line = line + 1, column = pos - buffer:line_start(line) + 1 }
end

local SEVERITY = { "error", "warning", "info", "hint" }

agent.tool({
	name = "focus",
	description = "What the user is looking at: the current file, their selections "
		.. "with the selected text, and the lines on screen",
	run = function()
		local view = kern.view()
		local buffer = view:buffer()
		local selection = view:selection()
		local selections = {}
		for i, range in selection.ranges do
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			table.insert(selections, {
				primary = i == selection.primary,
				from = position(buffer, from),
				to = position(buffer, to),
				text = buffer:slice(from, to),
			})
		end
		local first, last = view:visible()
		return {
			path = buffer:path(),
			kind = buffer:kind(),
			language = buffer:language(),
			modified = buffer:modified(),
			mode = kern.mode.get(),
			selections = selections,
			visible = { from = position(buffer, first).line, to = position(buffer, last).line },
		}
	end,
})

agent.tool({
	name = "buffers",
	description = "The files open in the editor, and which have unsaved changes",
	run = function()
		local list = {}
		for _, buffer in kern.buffers() do
			local path = buffer:path()
			if path then
				table.insert(
					list,
					{ path = path, modified = buffer:modified(), language = buffer:language() }
				)
			end
		end
		return kern.json.array(list)
	end,
})

agent.tool({
	name = "read",
	description = "A file's text as the editor has it, including unsaved changes. "
		.. "Lines are 1-based and both ends are included",
	input = object({
		path = { type = "string", description = "The file; the current one if left out" },
		from_line = { type = "integer" },
		to_line = { type = "integer" },
	}),
	run = function(args)
		local path: string? = args.path
		local buffer = if path then find_buffer(path) else kern.view():buffer()
		local text: string
		if buffer then
			text = buffer:text()
		else
			local read, err = kern.fs.read(path :: string)
			if read == nil then
				error(err, 0)
			end
			text = read
		end
		if args.from_line == nil and args.to_line == nil then
			return text
		end
		local lines = string.split(text, "\n")
		local from = math.max(args.from_line or 1, 1)
		local to = math.min(args.to_line or #lines, #lines)
		return table.concat(lines, "\n", from, to)
	end,
})

agent.tool({
	name = "diagnostics",
	description = "Errors and warnings from language servers, for one open file or all of them",
	input = object({
		path = { type = "string", description = "The file; every open file if left out" },
	}),
	run = function(args)
		local list = {}
		local wanted: kern.Buffer? = if args.path then find_buffer(args.path :: string) else nil
		for _, buffer in kern.buffers() do
			local path = buffer:path()
			if path and (args.path == nil or (wanted and wanted:id() == buffer:id())) then
				for _, d in kern.lsp.diagnostics(buffer) do
					local at = position(buffer, d.from)
					table.insert(list, {
						path = path,
						line = at.line,
						column = at.column,
						severity = SEVERITY[d.severity] or "hint",
						message = d.message,
						source = d.source,
					})
				end
			end
		end
		return kern.json.array(list)
	end,
})

agent.tool({
	name = "open",
	description = "Open a file in the editor for the user, optionally at a 1-based line",
	input = object({ path = { type = "string" }, line = { type = "integer" } }, { "path" }),
	run = function(args)
		kern.open(args.path)
		if args.line then
			local view = kern.view()
			local buffer = view:buffer()
			local at = buffer:line_start(math.clamp(args.line - 1, 0, buffer:line_count() - 1))
			view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end
		return `opened {args.path}`
	end,
})

agent.tool({
	name = "eval",
	description = "Run Luau inside the editor with the full plugin API "
		.. "(require('@kern')), and get back what it returns",
	input = object({ code = { type = "string" } }, { "code" }),
	run = function(args)
		local ok, result = kern.eval(args.code)
		if not ok then
			error(result, 0)
		end
		return result
	end,
})

agent.tool({
	name = "project",
	description = "The project's root folder",
	run = function()
		return core.project.root()
	end,
})

return {}

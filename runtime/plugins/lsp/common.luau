-- Helpers the language server commands share.

local greed = require("@greed")
local core = require("@core")

local M = {}

function M.head(view: greed.View): number
	local selection = view:selection()
	return selection.ranges[selection.primary].head
end

function M.move_to(view: greed.View, pos: number)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

--- Parameters for requests about the position at `pos`.
function M.at(buffer: greed.Buffer, pos: number): any
	return {
		textDocument = { uri = greed.lsp.uri(buffer) },
		position = greed.lsp.position(buffer, pos),
	}
end

--- Sends `method` to the buffer's server with `params`. Returns whether it
--- got an answer, then the result, or nil and the error. Without a server
--- it says so.
function M.request(buffer: greed.Buffer, method: string, params: () -> any): (boolean, any, any)
	if buffer:path() == nil then
		greed.echo("no language server for this buffer")
		return false
	end
	local ok, result, err = pcall(function()
		return greed.lsp.request(buffer, method, params())
	end)
	if not ok then
		greed.echo(tostring(result))
		return false
	end
	return true, result, err
end

--- Asks the buffer's server about the position at `pos`, as `request` does.
function M.ask(buffer: greed.Buffer, method: string, pos: number): (boolean, any, any)
	return M.request(buffer, method, function()
		return M.at(buffer, pos)
	end)
end

local SEVERITY = { "error", "warning", "info", "hint" }

--- A severity's name: "error", "warning", "info" or "hint".
function M.severity(severity: number): string
	return SEVERITY[severity] or "problem"
end

--- A problem as one line, e.g. "error: bad word".
function M.describe(problem: { severity: number, message: string }): string
	return `{M.severity(problem.severity)}: {problem.message}`
end

--- `path` relative to the project's root, when it's inside it.
function M.shown_path(path: string): string
	local root = core.project.root() .. "/"
	if string.sub(path, 1, #root) == root then
		return string.sub(path, #root + 1)
	end
	return path
end

--- Opens `path` in the main view at an LSP `position`.
function M.open_at(path: string, position: greed.LspPosition)
	greed.open(path)
	local view = greed.view()
	M.move_to(view, greed.lsp.offset(view:buffer(), position))
end

--- The text of the file at `path`: its buffer's if it's open, otherwise
--- what's on disk.
function M.file_text(path: string): string?
	for _, buffer in greed.buffers() do
		if buffer:path() == path then
			return buffer:text()
		end
	end
	return (greed.fs.read(path))
end

return M

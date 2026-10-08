-- Helpers the language server commands share.

local greed = require("@greed")

local M = {}

--- Parameters for requests about the position at `pos`.
function M.at(buffer: greed.Buffer, pos: number): any
	return {
		textDocument = { uri = greed.lsp.uri(buffer) },
		position = greed.lsp.position(buffer, pos),
	}
end

--- Why `buffer` has no language server, in words: none for files like it,
--- its server isn't installed, or it hasn't started.
function M.no_server(buffer: greed.Buffer): string
	local language = buffer:language()
	local commands: { { string } }? = if buffer:path() and language
		then greed.lsp.servers()[language]
		else nil
	if language == nil or commands == nil or #commands == 0 then
		return "no language server for this buffer"
	end
	for _, command in commands do
		if greed.which(command[1]) then
			return `the {language} language server ({command[1]}) isn't running yet`
		end
	end
	return `no language server for {language}: {commands[1][1]} isn't installed`
end

--- Sends `method` to the buffer's server with `params`. Returns whether it
--- got an answer, then the result, or nil and the error. Without a server
--- it says so.
function M.request(buffer: greed.Buffer, method: string, params: () -> any): (boolean, any, any)
	if buffer:path() == nil then
		greed.echo(M.no_server(buffer))
		return false
	end
	local ok, result, err = pcall(function()
		return greed.lsp.request(buffer, method, params())
	end)
	if not ok then
		local message = tostring(result)
		greed.echo(
			if string.find(message, "no language server", 1, true)
				then M.no_server(buffer)
				else message
		)
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

--- Opens `path` in the main view at an LSP `position`.
function M.open_at(path: string, position: greed.LspPosition)
	require("@core").file.open(path)
	local view = greed.view()
	view:set_cursor(greed.lsp.offset(view:buffer(), position))
end

return M

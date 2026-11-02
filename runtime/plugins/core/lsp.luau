-- Which of a buffer's language servers to ask for what. A buffer may have
-- several, its language's main one first, like TypeScript's with eslint
-- beside it: each feature goes to the servers that may be used for it (as
-- their `only` and `except` say) and say they can do it. Requests that want
-- one answer, like hover, go to the first of those; completion and code
-- actions ask them all.

local greed = require("@greed")

local M = {}

-- Each method's feature, as `only` and `except` name them, and the
-- capability that says a server does it.
local METHODS: { [string]: { feature: string, provider: string } } = {
	["textDocument/hover"] = { feature = "hover", provider = "hoverProvider" },
	["textDocument/definition"] = { feature = "definition", provider = "definitionProvider" },
	["textDocument/declaration"] = { feature = "definition", provider = "declarationProvider" },
	["textDocument/typeDefinition"] = {
		feature = "definition",
		provider = "typeDefinitionProvider",
	},
	["textDocument/implementation"] = {
		feature = "definition",
		provider = "implementationProvider",
	},
	["textDocument/references"] = { feature = "references", provider = "referencesProvider" },
	["textDocument/prepareRename"] = { feature = "rename", provider = "renameProvider" },
	["textDocument/rename"] = { feature = "rename", provider = "renameProvider" },
	["textDocument/codeAction"] = { feature = "code-action", provider = "codeActionProvider" },
	["textDocument/completion"] = { feature = "completion", provider = "completionProvider" },
	["textDocument/signatureHelp"] = {
		feature = "signature-help",
		provider = "signatureHelpProvider",
	},
	["textDocument/formatting"] = {
		feature = "format",
		provider = "documentFormattingProvider",
	},
	["workspace/symbol"] = { feature = "symbols", provider = "workspaceSymbolProvider" },
}

--- The features servers may be set up for or kept from, by name.
M.FEATURES = {
	"hover",
	"definition",
	"references",
	"rename",
	"code-action",
	"completion",
	"signature-help",
	"format",
	"symbols",
}

-- Whether `server` may be used for `feature`.
local function allowed(server: greed.LspBufferServer, feature: string): boolean
	if #server.only > 0 and not table.find(server.only, feature) then
		return false
	end
	return table.find(server.except, feature) == nil
end

--- The buffer's servers to ask `method`, in order: those that may be used
--- for its feature and say they can do it. A method this doesn't know goes
--- to all of them.
function M.servers(buffer: greed.Buffer, method: string): { greed.LspBufferServer }
	local found = {}
	local known = METHODS[method]
	for _, server in greed.lsp.servers_of(buffer) do
		local capable = known == nil
			or (
				allowed(server, known.feature)
				and server.capabilities ~= nil
				and server.capabilities[known.provider] ~= nil
				and server.capabilities[known.provider] ~= false
			)
		if capable then
			table.insert(found, server)
		end
	end
	return found
end

--- The id of the buffer's server to ask `method` when one answer is
--- wanted: the first of `servers`. Nil when none can, or it has none.
function M.server(buffer: greed.Buffer, method: string): number?
	local first = M.servers(buffer, method)[1]
	return if first then first.id else nil
end

--- The problems `server` reported in `from`..`to` of `buffer`, as it sent
--- them (every server's without one), where they are now: what goes in a
--- code action request's context, which a server finds its fixes by.
function M.problems_in(buffer: greed.Buffer, from: number, to: number, server: number?): { any }
	local list = {}
	for _, d in greed.lsp.diagnostics(buffer) do
		if d.from <= to and from <= d.to and (server == nil or d.server == server) then
			table.insert(list, {
				range = {
					start = greed.lsp.position(buffer, d.from, server),
					["end"] = greed.lsp.position(buffer, d.to, server),
				},
				severity = d.severity,
				message = d.message,
				source = d.source,
				code = d.code,
				data = d.data,
			})
		end
	end
	return list
end

--- Calls `ask` with the id of each of the buffer's `servers` for `method`,
--- in order, for requests every one answers, like completion; once with
--- nil, for its first, when none says it can.
function M.each(buffer: greed.Buffer, method: string, ask: (server: number?) -> ())
	local found = M.servers(buffer, method)
	if #found == 0 then
		ask(nil)
		return
	end
	for _, server in found do
		ask(server.id)
	end
end

return M

-- The models a provider offers, as its API lists them, kept for a while so
-- the pickers that show them open at once.

local greed = require("@greed")

local M = {}

--- Sends `request` with greed.http. Tests replace it.
function M.request(request: greed.HttpRequest): (greed.HttpResponse?, string?)
	return greed.http.request(request)
end

--- How long a provider's list is kept, in milliseconds.
M.KEEP = 10 * 60 * 1000

type Kept = { url: string, at: number, ids: { string } }

local kept: { [string]: Kept } = {}

--- The list kept for the provider `name` at `url`, while it's recent.
function M.kept(name: string, url: string): { string }?
	local found = kept[name]
	if found and found.url == url and greed.now() - found.at < M.KEEP then
		return table.clone(found.ids)
	end
	return nil
end

--- Keeps `ids` as the list of the provider `name` at `url`.
function M.keep(name: string, url: string, ids: { string })
	kept[name] = { url = url, at = greed.now(), ids = table.clone(ids) }
end

--- Forgets every list kept.
function M.forget()
	kept = {}
end

--- The model ids in a listing's `body`, sorted: Ollama's `/api/tags`
--- (`models[].name`, without ":latest") when `ollama`, else `data[].id`,
--- as OpenAI's and Anthropic's APIs list them.
function M.ids(body: string, ollama: boolean): { string }
	local ok, decoded = pcall(greed.json.decode, body)
	local listed = if ok and type(decoded) == "table"
		then (if ollama then decoded.models else decoded.data)
		else nil
	local field = if ollama then "name" else "id"
	local ids: { string } = {}
	if type(listed) == "table" then
		for _, model in listed :: { any } do
			local id = type(model) == "table" and model[field]
			if type(id) == "string" then
				table.insert(ids, if ollama then (string.gsub(id, ":latest$", "")) else id)
			end
		end
	end
	table.sort(ids)
	return ids
end

return M

-- Tools for searching the web and reading pages, in the `web` group, off
-- until an agent switches it on. What comes back is written by strangers,
-- so it reaches the agent marked as untrusted, and the agent's edits and
-- commands still wait for you as they always do.
--
-- Searching needs a service: `:set web-search brave` (or exa, tavily,
-- searxng) and its key with `:secret-set brave`; SearXNG needs no key,
-- just `:set web-search-url https://your.searx`.

local greed = require("@greed")
local registry = require("./registry")
local untrusted = require("./untrusted").wrap

greed.option.define({
	name = "web-search",
	default = "",
	choices = { "", "brave", "exa", "tavily", "searxng" },
	doc = 'The search service agents search the web with: "brave", "exa", "tavily" or "searxng"; empty for none',
})

greed.option.define({
	name = "web-search-url",
	needs = "net",
	default = "",
	doc = "Where your SearXNG is, for web-search searxng",
})

local M = {}

-- The most of a page an agent gets, in characters.
local MOST = 20000

--- Sends `request` with greed.http. Tests replace it.
function M.request(request: greed.HttpRequest): (greed.HttpResponse?, string?)
	return greed.http.request(request)
end

local function encode(text: string): string
	return (
		string.gsub(text, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local ENTITIES: { [string]: string } =
	{ amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- Tags whose text goes on lines of its own.
local BLOCKS: { [string]: boolean } = {}
for _, name in
	string.split("p br div li tr section article h1 h2 h3 h4 h5 h6 pre blockquote ul ol table", " ")
do
	BLOCKS[name] = true
end

--- A page's readable text: no scripts, styles or tags, blocks on lines of
--- their own, entities decoded.
function M.text_of(html: string): string
	local text = html
	for _, tag in { "script", "style", "noscript", "svg", "head" } do
		text = string.gsub(text, `<{tag}[^>]*>.-</{tag}>`, " ")
	end
	text = string.gsub(text, "<!%-%-.-%-%->", " ")
	text = string.gsub(text, "</?%a[%w]*%f[%s>/][^>]*>", function(tag: string): string
		local name = string.lower(string.match(tag, "^</?(%a[%w]*)") or "")
		return if BLOCKS[name] then "\n" else ""
	end)
	text = string.gsub(text, "&#(%d+);", function(n: string): string
		local code = tonumber(n)
		return if code and code < 0x110000 then utf8.char(code) else ""
	end)
	text = string.gsub(text, "&#x(%x+);", function(n: string): string
		local code = tonumber(n, 16)
		return if code and code < 0x110000 then utf8.char(code) else ""
	end)
	text = string.gsub(text, "&(%a+);", function(name: string): string
		return ENTITIES[name] or `&{name};`
	end)
	text = string.gsub(text, "[ \t\r]+", " ")
	text = string.gsub(text, " ?\n[ \n]*", "\n")
	return (string.match(text, "^%s*(.-)%s*$") or "")
end

-- Whether `url` points at this machine or a private network (a router, a
-- metadata service, a dev server): a page an agent reads can't send it
-- there. Names are judged as written, so a public name for a private
-- address still gets through; it shuts the plain cases.
local function private(url: string): boolean
	local host = string.lower(
		string.match(url, "^https?://%[([^%]]+)%]")
			or string.match(url, "^https?://[^/?#@]*@([^/:?#]+)")
			or string.match(url, "^https?://([^/:?#]+)")
			or ""
	)
	if
		host == "localhost"
		or string.match(host, "%.localhost$")
		or string.match(host, "%.local$")
	then
		return true
	end
	local a, b = string.match(host, "^(%d+)%.(%d+)%.%d+%.%d+$")
	local first, second = tonumber(a), tonumber(b)
	if first and second then
		return first == 127
			or first == 10
			or first == 0
			or (first == 169 and second == 254)
			or (first == 192 and second == 168)
			or (first == 172 and second >= 16 and second <= 31)
			or (first == 100 and second >= 64 and second <= 127)
	end
	return host == "::1"
		or string.match(host, "^f[cd]") ~= nil
		or string.match(host, "^fe80:") ~= nil
end

--- Fetches `url` (http or https) and returns its text, cut at MOST
--- characters, or fails with why. Redirects are followed, a few, never to
--- this machine or a private network.
function M.fetch(url: string): string
	if not string.match(url, "^https?://") then
		error("only http and https addresses", 0)
	end
	local response, err
	for _ = 1, 5 do
		if private(url) then
			error(`{url} is on this machine or a private network, which agents don't fetch from`, 0)
		end
		response, err = M.request({ url = url, method = "GET", timeout = 20000 })
		local location = response and response.headers.location
		if not (response and response.status >= 300 and response.status < 400 and location) then
			break
		end
		url = if string.match(location, "^https?://")
			then location
			else (string.match(url, "^(https?://[^/?#]+)") or "") .. location
	end
	if response == nil then
		error(`can't fetch {url}: {err}`, 0)
	elseif response.status >= 300 then
		error(`{url} answered {response.status}`, 0)
	end
	local kind = response.headers["content-type"] or ""
	local text = if string.find(kind, "html", 1, true)
		then M.text_of(response.body)
		else response.body
	if #text > MOST then
		text = string.sub(text, 1, MOST) .. "\n(cut short)"
	end
	return text
end

export type Found = { title: string, url: string, snippet: string }

-- The key for `service`, or a failure saying how to set it.
local function key(service: string): string
	local found = greed.secrets.get(service)
	if found == nil then
		error(
			`no key for {service}: :secret-set {service}, or set {greed.secrets.variable(service)}`,
			0
		)
	end
	return found
end

local function answer(response: greed.HttpResponse?, err: string?, service: string): any
	if response == nil then
		error(`can't reach {service}: {err}`, 0)
	elseif response.status >= 300 then
		error(`{service} answered {response.status}: {string.sub(response.body, 1, 200)}`, 0)
	end
	local ok, decoded = pcall(greed.json.decode, response.body)
	if not ok or type(decoded) ~= "table" then
		error(`{service} answered with something that isn't JSON`, 0)
	end
	return decoded
end

-- How each service is searched: the results for `query`.
local SERVICES: { [string]: (query: string) -> { Found } } = {
	brave = function(query)
		local response, err = M.request({
			url = `https://api.search.brave.com/res/v1/web/search?q={encode(query)}`,
			method = "GET",
			headers = { accept = "application/json", ["x-subscription-token"] = key("brave") },
			timeout = 20000,
		})
		local found = {}
		for _, item in (answer(response, err, "brave").web or {}).results or {} do
			table.insert(
				found,
				{ title = item.title, url = item.url, snippet = item.description or "" }
			)
		end
		return found
	end,
	exa = function(query)
		local response, err = M.request({
			url = "https://api.exa.ai/search",
			method = "POST",
			headers = { ["content-type"] = "application/json", ["x-api-key"] = key("exa") },
			body = greed.json.encode({
				query = query,
				numResults = 8,
				contents = { highlights = true },
			}),
			timeout = 20000,
		})
		local found = {}
		for _, item in answer(response, err, "exa").results or {} do
			local highlights = item.highlights or {}
			table.insert(found, {
				title = item.title or item.url,
				url = item.url,
				snippet = table.concat(highlights, " … "),
			})
		end
		return found
	end,
	tavily = function(query)
		local response, err = M.request({
			url = "https://api.tavily.com/search",
			method = "POST",
			headers = {
				["content-type"] = "application/json",
				authorization = `Bearer {key("tavily")}`,
			},
			body = greed.json.encode({ query = query, max_results = 8 }),
			timeout = 20000,
		})
		local found = {}
		for _, item in answer(response, err, "tavily").results or {} do
			table.insert(
				found,
				{ title = item.title, url = item.url, snippet = item.content or "" }
			)
		end
		return found
	end,
	searxng = function(query)
		local base = greed.option.get("web-search-url") :: string
		if base == "" then
			error("web-search is searxng, but web-search-url doesn't say where it is", 0)
		end
		local response, err = M.request({
			url = `{string.gsub(base, "/+$", "")}/search?q={encode(query)}&format=json`,
			method = "GET",
			timeout = 20000,
		})
		local found = {}
		for i, item in answer(response, err, "searxng").results or {} do
			if i > 8 then
				break
			end
			table.insert(
				found,
				{ title = item.title, url = item.url, snippet = item.content or "" }
			)
		end
		return found
	end,
}

--- The web's results for `query`, from the service the web-search option
--- names, or fails with why (and how to set one up).
function M.search(query: string): { Found }
	local service = greed.option.get("web-search") :: string
	local search = SERVICES[service]
	if search == nil then
		error(
			"no search service: :set web-search brave (or exa, tavily, searxng) and :secret-set its key",
			0
		)
	end
	return search(query)
end

registry.group(
	"web",
	"Searching the web and reading pages, for documentation and facts the project doesn't have"
)

registry.tool({
	name = "web_search",
	group = "web",
	kind = "fetch",
	description = "Search the web: the results' titles, addresses and a line from each. "
		.. "Read a promising one with web_fetch",
	input = registry.schema.object({ query = { type = "string" } }, { "query" }),
	run = function(args)
		local lines = {}
		for i, found in M.search(args.query) do
			table.insert(lines, `{i}. {found.title}\n{found.url}\n{found.snippet}`)
		end
		if #lines == 0 then
			return "nothing found"
		end
		return untrusted(`a web search for "{args.query}"`, table.concat(lines, "\n\n"))
	end,
})

registry.tool({
	name = "web_fetch",
	group = "web",
	kind = "fetch",
	description = "Read a web page (http or https) as text, without its markup",
	input = registry.schema.object({ url = { type = "string" } }, { "url" }),
	run = function(args)
		return untrusted(args.url, M.fetch(args.url))
	end,
})

return M

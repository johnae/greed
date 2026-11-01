-- Tools for reading pages, always there, and searching the web, in the
-- `web` group, off until an agent switches it on. What comes back is
-- written by strangers, so it reaches the agent marked as untrusted, and
-- the agent's edits and commands still wait for you as they always do.
--
-- Searching needs a service: `:set web-search brave` (or exa, tavily,
-- searxng) and its key with `:secret-set brave`; SearXNG needs no key,
-- just `:set web-search-url https://your.searx`.

local core = require("@core")
local greed = require("@greed")
local registry = require("./registry")
local models: any = require("@models")
local untrusted = require("./untrusted").wrap
local untrusted_note = require("./untrusted").NOTE

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

greed.option.define({
	name = "web-sources",
	default = "",
	doc = 'Domains whose results agents\' searches show first, like "reuters.com docs.rs"; '
		.. "a domain counts its subdomains too",
})

greed.option.define({
	name = "web-sources-only",
	default = false,
	doc = "Agents' searches show only results from the web-sources domains",
})

local M = {}

-- The most of a page an agent gets, in characters.
local MOST = 20000

-- The most of a result's lines an agent gets, in characters. Uncapped,
-- Exa's come as whole sections of the page, and one search costs as much
-- as reading several pages.
local SNIPPET = 1000

--- Sends `request` with greed.http. Tests replace it.
function M.request(request: greed.HttpRequest): (greed.HttpResponse?, string?)
	return greed.http.request(request)
end

local encode = core.text.percent_encode

--- A page's text to read, as Markdown: its title, its summary when the
--- text leaves it out, and its main content.
function M.text_of(html: string, url: string?): string
	local page = greed.html.read(html, url)
	local parts = {}
	if page.title and not string.find(page.text, page.title, 1, true) then
		table.insert(parts, `# {page.title}`)
	end
	if page.excerpt and not string.find(page.text, page.excerpt, 1, true) then
		table.insert(parts, page.excerpt)
	end
	table.insert(parts, page.text)
	return table.concat(parts, "\n\n")
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
		then M.text_of(response.body, url)
		else response.body
	if #text > MOST then
		text = string.sub(text, 1, MOST) .. "\n(cut short)"
	end
	return text
end

--- A result: its title, address and a line from it, and for news when
--- it's from, when the service says.
export type Found = { title: string, url: string, snippet: string, date: string? }

-- When a result is from, as a service gives it: the day of a timestamp,
-- other forms as they are.
local function day(given: any): string?
	if type(given) ~= "string" or given == "" then
		return nil
	end
	return string.match(given, "^(%d%d%d%d%-%d%d%-%d%d)") or given
end

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

-- How each service is searched: the results for `query`, or with `news`
-- the news about it.
local SERVICES: { [string]: (query: string, news: boolean) -> { Found } } = {
	brave = function(query, news)
		local kind = if news then "news" else "web"
		local response, err = M.request({
			url = `https://api.search.brave.com/res/v1/{kind}/search?q={encode(query)}`,
			method = "GET",
			headers = { accept = "application/json", ["x-subscription-token"] = key("brave") },
			timeout = 20000,
		})
		local answered = answer(response, err, "brave")
		-- Its news results are at the top, its web results under `web`.
		local results = if news then answered.results else (answered.web or {}).results
		local found = {}
		for _, item in results or {} do
			table.insert(found, {
				title = item.title,
				url = item.url,
				snippet = item.description or "",
				date = day(item.page_age),
			})
		end
		return found
	end,
	exa = function(query, news)
		local response, err = M.request({
			url = "https://api.exa.ai/search",
			method = "POST",
			headers = { ["content-type"] = "application/json", ["x-api-key"] = key("exa") },
			body = greed.json.encode({
				query = query,
				numResults = 8,
				category = if news then "news" else nil,
				contents = { highlights = { maxCharacters = SNIPPET } },
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
				date = day(item.publishedDate),
			})
		end
		return found
	end,
	tavily = function(query, news)
		local response, err = M.request({
			url = "https://api.tavily.com/search",
			method = "POST",
			headers = {
				["content-type"] = "application/json",
				authorization = `Bearer {key("tavily")}`,
			},
			body = greed.json.encode({
				query = query,
				max_results = 8,
				topic = if news then "news" else nil,
			}),
			timeout = 20000,
		})
		local found = {}
		for _, item in answer(response, err, "tavily").results or {} do
			table.insert(found, {
				title = item.title,
				url = item.url,
				snippet = item.content or "",
				date = day(item.published_date),
			})
		end
		return found
	end,
	searxng = function(query, news)
		local base = greed.option.get("web-search-url") :: string
		if base == "" then
			error("web-search is searxng, but web-search-url doesn't say where it is", 0)
		end
		local category = if news then "&categories=news" else ""
		local response, err = M.request({
			url = `{string.gsub(base, "/+$", "")}/search?q={encode(query)}&format=json{category}`,
			method = "GET",
			timeout = 20000,
		})
		local found = {}
		for i, item in answer(response, err, "searxng").results or {} do
			if i > 8 then
				break
			end
			table.insert(found, {
				title = item.title,
				url = item.url,
				snippet = item.content or "",
				date = day(item.publishedDate),
			})
		end
		return found
	end,
}

-- Whether `url` is on one of the domains in `sources`, or under one.
local function trusted(url: string, sources: { string }): boolean
	local host = string.lower(string.match(url, "^https?://([^/?#:]+)") or "")
	for _, source in sources do
		if host == source or string.sub(host, -#source - 1) == "." .. source then
			return true
		end
	end
	return false
end

--- The web's results for `query`, from the service the web-search option
--- names, or fails with why (and how to set one up).
function M.search(query: string, news: boolean?): { Found }
	local service = greed.option.get("web-search") :: string
	local search = SERVICES[service]
	if search == nil then
		error(
			"no search service: :set web-search brave (or exa, tavily, searxng) and :secret-set its key",
			0
		)
	end
	local found = search(query, news == true)
	for _, item in found do
		item.snippet = core.text.clip(item.snippet, SNIPPET)
	end
	-- The sources you trust first, in the service's order, or only them.
	local sources = {}
	for source in string.gmatch(string.lower(greed.option.get("web-sources") :: string), "%S+") do
		table.insert(sources, source)
	end
	if #sources == 0 then
		return found
	end
	local first, rest = {}, {}
	for _, item in found do
		table.insert(if trusted(item.url, sources) then first else rest, item)
	end
	if greed.option.get("web-sources-only") ~= true then
		table.move(rest, 1, #rest, #first + 1, first)
	end
	return first
end

registry.group("web", "Searching the web, for documentation and facts the project doesn't have")

registry.tool({
	name = "web_search",
	group = "web",
	kind = "fetch",
	description = "Search the web: the results' titles, addresses and a line from each. "
		.. "Read a promising one with web_fetch. With news, recent news about it, dated",
	input = registry.schema.object({
		query = { type = "string" },
		news = { type = "boolean", description = "Search the news rather than the whole web" },
	}, { "query" }),
	run = function(args)
		local lines = {}
		for i, found in M.search(args.query, args.news) do
			local line = if found.date then `{found.date}: {found.snippet}` else found.snippet
			table.insert(lines, `{i}. {found.title}\n{found.url}\n{line}`)
		end
		if #lines == 0 then
			return "nothing found"
		end
		return untrusted(`a web search for "{args.query}"`, table.concat(lines, "\n\n"))
	end,
})

-- What the fast model is told when it answers a question from a page.
local READER = "You answer a question about a web page from what the page says, briefly. "
	.. "Quote the lines you rely on. If the page doesn't answer it, say so and say what it "
	.. "is about instead. "
	.. untrusted_note

--- What `question` gets for an answer from `page`, the text of `url`, by
--- the fast model. Nil when there's no fast model to ask.
function M.answer(url: string, page: string, question: string): string?
	if not models.resolve("fast") then
		return nil
	end
	local answer, err = models.ask("fast", {
		system = READER,
		max_tokens = 1000,
		temperature = 0,
		messages = { { role = "user", content = `{question}\n\n{untrusted(url, page)}` } },
	})
	if answer == nil then
		error(`the fast model couldn't read {url}: {err}`, 0)
	end
	return answer
end

-- In no group: a link the user gives is read without switching one on.
registry.tool({
	name = "web_fetch",
	kind = "fetch",
	description = "Read a web page (http or https) as Markdown, its main content without "
		.. "menus and footers. With question, a small model reads it and only its answer "
		.. "comes back: for a fact from a page rather than all of it",
	input = registry.schema.object({
		url = { type = "string" },
		question = { type = "string", description = "What to find out from the page" },
	}, { "url" }),
	run = function(args)
		local page = M.fetch(args.url)
		if args.question == nil then
			return untrusted(args.url, page)
		end
		local answer = M.answer(args.url, page, args.question)
		if answer == nil then
			return "No fast model to answer with (:models), so the whole page.\n\n"
				.. untrusted(args.url, page)
		end
		return untrusted(`what {args.url} says, as a model read it`, answer)
	end,
})

return M

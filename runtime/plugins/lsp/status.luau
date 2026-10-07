-- The language server in the status line: its name while it runs, what
-- it's working on as it reports progress (`rust-analyzer: indexing 40%`),
-- and whether it's starting, stopped or not installed.

local greed = require("@greed")
local core = require("@core")
local statusline = require("@statusline")

local M = {}

-- Work each language's server reports, by progress token, in the order it
-- began.
type Work = { token: string, title: string, message: string?, percentage: number? }
local working: { [string]: { Work } } = {}
-- The program each language's server runs, false when none is installed;
-- looked up once per language, as finding programs reads folders.
local programs: { [string]: string | false } = {}
-- Languages whose server has answered, so it not answering now means it stopped.
local seen: { [string]: boolean } = {}

local function program(language: string): string | false
	local known: (string | false)? = programs[language]
	if known ~= nil then
		return known
	end
	local found: string | false = false
	local commands: { { string } } = greed.lsp.servers()[language] or {}
	for _, command in commands do
		if greed.which(command[1]) then
			found = core.project.basename(command[1]) or command[1]
			break
		end
	end
	programs[language] = found
	return found
end

--- Takes in a `$/progress` notification from `language`'s server.
function M.progress(language: string, params: any)
	local token, value = tostring(params.token), params.value or {}
	local list: { Work } = working[language] or {}
	working[language] = list
	local at
	for i, work in list do
		if work.token == token then
			at = i
		end
	end
	if value.kind == "begin" then
		table.insert(list, {
			token = token,
			title = value.title or "",
			message = value.message,
			percentage = value.percentage,
		})
	elseif value.kind == "report" and at then
		list[at].message = value.message or list[at].message
		list[at].percentage = value.percentage or list[at].percentage
	elseif value.kind == "end" and at then
		table.remove(list, at)
	end
end

--- What the status line shows for `buffer`'s server, or nil without one.
function M.text(buffer: greed.Buffer): string?
	local language = buffer:language()
	if language == nil then
		return nil
	end
	local commands = greed.lsp.servers()[language]
	if commands == nil then
		return nil
	end
	local name: string | false = program(language)
	if not name then
		local wanted = commands[1]
		return `{wanted and wanted[1] or "server"} not installed`
	end
	if greed.lsp.capabilities(buffer) == nil then
		-- A server that stopped took its work with it.
		working[language] = nil
		return if seen[language] then `{name} stopped` else `{name} starting`
	end
	seen[language] = true
	local work = M.work(language)
	return if work then `{name}: {work}` else name
end

--- What `language`'s server is working on, e.g. "indexing 3/10 40%", or
--- nil when it's idle. The oldest work shows.
function M.work(language: string): string?
	local work = (working[language] or {})[1]
	if work == nil then
		return nil
	end
	local what = string.lower(work.title)
	if work.message and work.message ~= "" then
		what ..= ` {work.message}`
	end
	if work.percentage then
		what ..= ` {math.floor(work.percentage)}%`
	end
	return what
end

greed.lsp.on_notification("$/progress", M.progress)

-- A server installed since gets found the next time a file opens.
greed.on("buffer.opened", function()
	table.clear(programs)
end)

statusline.add("right", "server", function(ctx)
	return M.text(ctx.buffer)
end, "style")

return M

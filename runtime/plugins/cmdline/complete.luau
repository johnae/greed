-- What the command line offers as you type: command names first, then
-- each argument as the command describes it.

local kern = require("@kern")
local parse = require("./parse")

export type Candidate = {
	--- What replaces the word being typed.
	text: string,
	--- Shown next to it.
	doc: string?,
}

--- Finds candidates for `word`, the argument typed so far. They're ranked
--- against `word` afterwards, so a completer can return everything.
export type Completer = (word: string) -> { Candidate }

local M = {}

local completers: { [string]: Completer } = {}

function M.register(name: string, completer: Completer)
	completers[name] = completer
end

-- The items matching `word`: exact matches, then ones starting with it,
-- then other fuzzy matches.
local function rank(word: string, items: { Candidate }): { Candidate }
	local texts = {}
	for i, item in items do
		texts[i] = item.text
	end
	local exact, prefix, rest = {}, {}, {}
	for _, i in kern.fuzzy(word, texts) do
		local item = items[i]
		if item.text == word then
			table.insert(exact, item)
		elseif string.sub(item.text, 1, #word) == word then
			table.insert(prefix, item)
		else
			table.insert(rest, item)
		end
	end
	table.move(prefix, 1, #prefix, #exact + 1, exact)
	table.move(rest, 1, #rest, #exact + 1, exact)
	return exact
end

M.register("command", function()
	local items = {}
	for _, command in kern.commands() do
		table.insert(items, { text = command.name, doc = command.doc })
	end
	return items
end)

M.register("option", function()
	local items = {}
	for _, option in kern.option.list() do
		table.insert(items, { text = option.name, doc = option.doc .. " (now " .. tostring(option.value) .. ")" })
	end
	return items
end)

M.register("buffer", function()
	local items = {}
	for _, buffer in kern.buffers() do
		local path = buffer:path()
		if path then
			table.insert(items, { text = path })
		end
	end
	return items
end)

-- Paths one directory at a time: "src/" lists what's in src.
M.register("file", function(word)
	local dir = string.match(word, "^(.*/)") or ""
	local entries = kern.fs.list(if dir == "" then "." else dir) or {}
	local items = {}
	for _, entry in entries do
		table.insert(items, { text = dir .. entry.name .. (if entry.dir then "/" else "") })
	end
	return items
end)

-- Candidates for the last word of `line`, and that word. `first` lists
-- what the first word can be; `resolve` turns it into a command name.
function M.candidates(line: string, first: { Candidate }, resolve: (name: string) -> string): ({ Candidate }, string)
	local typed = string.match(line, "^%s*(.*)$") or ""
	if not string.find(typed, "%s") then
		return rank(typed, first), typed
	end
	local parsed = parse.parse(typed)
	if parsed == nil then
		return {}, ""
	end
	local name = resolve(parsed.name)
	local index, word = #parsed.args, parsed.args[#parsed.args] or ""
	if string.find(typed, "%s$") then
		index, word = index + 1, ""
	end
	for _, command in kern.commands() do
		if command.name == name then
			local spec = command.args[index]
			local completer = spec and spec.complete and completers[spec.complete]
			return (if completer then rank(word, completer(word)) else {}), word
		end
	end
	return {}, ""
end

return M

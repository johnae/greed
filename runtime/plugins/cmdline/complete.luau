-- What the command line offers as you type: command names first, then
-- each argument as the command describes it.

local greed = require("@greed")
local parse = require("./parse")
local core = require("@core")

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

--- Shows what a candidate would do while tab is on it, like a theme; nil
--- when the command line closes without running, to undo that.
export type Preview = (text: string?) -> ()

local completers: { [string]: Completer } = {}
local previews: { [string]: Preview? } = {}

function M.register(name: string, completer: Completer, preview: Preview?)
	completers[name] = completer
	previews[name] = preview
end

-- The items matching `word`: exact matches, then ones starting with it,
-- then other fuzzy matches.
local function rank(word: string, items: { Candidate }): { Candidate }
	local texts = {}
	for i, item in items do
		texts[i] = item.text
	end
	local exact, prefix, rest = {}, {}, {}
	for _, i in greed.fuzzy(word, texts) do
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
	for _, command in greed.commands() do
		table.insert(items, { text = command.name, doc = command.doc })
	end
	return items
end)

M.register("option", function()
	local items = {}
	for _, option in greed.option.list() do
		table.insert(
			items,
			{ text = option.name, doc = option.doc .. " (now " .. tostring(option.value) .. ")" }
		)
	end
	return items
end)

M.register("buffer", function()
	local items = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path then
			table.insert(items, { text = path })
		end
	end
	return items
end)

-- Paths one directory at a time: "src/" lists what's in src, "~/" the home
-- folder, and hidden ones show once what's typed starts with ".".
M.register("file", function(word)
	local dir = string.match(word, "^(.*/)") or ""
	local typed = string.sub(word, #dir + 1)
	local entries: { greed.DirEntry } = greed.fs.list(
		if dir == "" then "." else core.project.expand(dir),
		{
			hidden = string.sub(typed, 1, 1) == ".",
			ignored = true,
		}
	) or {}
	local items = {}
	for _, entry in entries do
		table.insert(items, { text = dir .. entry.name .. (if entry.dir then "/" else "") })
	end
	return items
end)

-- Candidates for the last word of `line`, that word, and the completer's
-- preview if it has one. `first` lists what the first word can be;
-- `resolve` turns it into a command name.
function M.candidates(
	line: string,
	first: { Candidate },
	resolve: (name: string) -> string
): ({ Candidate }, string, Preview?)
	local typed = string.match(line, "^%s*(.*)$") or ""
	if not string.find(typed, "%s") then
		return rank(typed, first), typed, nil
	end
	local parsed = parse.parse(typed)
	if parsed == nil then
		return {}, "", nil
	end
	local name = resolve(parsed.name)
	local index, word = #parsed.args, parsed.args[#parsed.args] or ""
	if string.find(typed, "%s$") then
		index, word = index + 1, ""
	end
	for _, command in greed.commands() do
		if command.name == name then
			local spec = command.args[index]
			local key = spec and spec.complete
			local completer = key and completers[key]
			return (if completer then rank(word, completer(word)) else {}),
				word,
				key and previews[key]
		end
	end
	return {}, "", nil
end

return M

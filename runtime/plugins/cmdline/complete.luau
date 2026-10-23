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

--- Finds candidates for `word`, the argument typed so far; `args` are the
--- arguments before it. They're ranked against `word` afterwards, so a
--- completer can return everything.
export type Completer = (word: string, args: { string }) -> { Candidate }

local M = {}

--- Shows what a candidate would do while tab is on it, like a theme; nil
--- when the command line closes without running, to undo that.
export type Preview = (text: string?) -> ()

local completers: { [string]: Completer } = {}
local previews: { [string]: Preview? } = {}

--- Adds the completer `name`, until the plugin that added it goes.
function M.register(name: string, completer: Completer, preview: Preview?)
	local remove = core.registry.set(completers, name, completer)
	previews[name] = preview
	greed.plugin.cleanup(function()
		if completers[name] == completer then
			remove()
			previews[name] = nil
		end
	end)
end

-- The items matching `word`: exact matches, then ones starting with it,
-- then other fuzzy matches.
local function rank(word: string, items: { Candidate }): { Candidate }
	local texts = {}
	for i, item in items do
		texts[i] = item.text
	end
	local exact, prefix, rest = {}, {}, {}
	for _, i in greed.fuzzy(word, texts, { case = core.search.case() }) do
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

-- The choices of the option named by the argument before, or true and
-- false for a yes-or-no one.
M.register("option-value", function(_, args)
	for _, option in greed.option.list() do
		if option.name == args[#args] then
			local items = {}
			local choices: { greed.OptionValue } = if #option.choices > 0
				then option.choices
				elseif type(option.default) == "boolean" then { true, false }
				else {}
			for _, choice in choices do
				table.insert(items, { text = tostring(choice) })
			end
			return items
		end
	end
	return {}
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

M.register("plugin", function()
	local items = {}
	for _, name in greed.plugin.list() do
		table.insert(items, { text = name })
	end
	return items
end)

-- Paths one directory at a time: "src/" lists what's in src, "~/" the home
-- folder, and hidden ones show once what's typed starts with ".". With
-- `folders`, only folders.
local function paths(word: string, folders: boolean): { Candidate }
	local dir = string.match(word, "^(.*/)") or ""
	local typed = string.sub(word, #dir + 1)
	local entries: { greed.DirEntry } = greed.fs.list(
		core.project.resolve(if dir == "" then "." else dir),
		{
			hidden = string.sub(typed, 1, 1) == ".",
			ignored = true,
		}
	) or {}
	local items = {}
	for _, entry in entries do
		if entry.dir or not folders then
			table.insert(items, { text = dir .. entry.name .. (if entry.dir then "/" else "") })
		end
	end
	return items
end

M.register("file", function(word)
	return paths(word, false)
end)

M.register("folder", function(word)
	return paths(word, true)
end)

M.register("boolean", function()
	return { { text = "true" }, { text = "false" } }
end)

-- What completes an argument that says its type but no `complete`: its
-- choices, or the objects of its kind, by label when that's one word and
-- else by the key in their id.
local function from_type(spec: greed.ArgSpec): Completer?
	local kind = spec.type
	if kind == "file" or kind == "folder" or kind == "boolean" then
		return completers[kind]
	elseif kind == "choice" then
		local choices: { string } = spec.choices or {}
		return function()
			local items = {}
			for _, choice in choices do
				table.insert(items, { text = choice })
			end
			return items
		end
	elseif kind == "object" and spec.kind then
		local of = spec.kind
		return function()
			local items = {}
			for _, object in core.objects.list(of) do
				local key = string.sub(object.id, #of + 2)
				local text = if string.find(object.label, "%s") then key else object.label
				table.insert(
					items,
					{ text = text, doc = if text ~= object.label then object.label else nil }
				)
			end
			return items
		end
	end
	return nil
end

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
			local spec: greed.ArgSpec? = command.args[index]
			-- A "rest" argument goes on for the words after it.
			if spec == nil then
				local last = command.args[#command.args]
				spec = if last and last.type == "rest" then last else nil
			end
			local key = spec and spec.complete
			local completer: Completer? = nil
			if key then
				completer = completers[key]
			elseif spec then
				completer = from_type(spec)
			end
			local before = table.move(parsed.args, 1, index - 1, 1, {})
			return (if completer then rank(word, completer(word, before)) else {}),
				word,
				key and previews[key]
		end
	end
	return {}, "", nil
end

return M

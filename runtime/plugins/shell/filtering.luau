-- The prompt a filter is typed in, in a block or a view showing one, and
-- what `tab` completes there from what the block printed: the sections of
-- its indented text (`.status.conditions`), the fields of its JSON lines
-- (`level=`, `HelmRelease.name=`) and its table's columns (`STATUS=`).

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local tables = require("./tables")

type Block = state.Block
type Item = { label: string, detail: string?, badge: string?, text: string, from: number? }

local M = {}

--- The kind of the prompt's buffer, for its keys.
M.KIND = "shell-filter-prompt"

-- How many lines of a block's output are read for what to complete.
local READ = 5000

-- The block whose filter is being typed, by the client typing it.
local filtering: { [number]: Block } = {}

core.style.typing_kind(M.KIND)
core.style.label_kind(M.KIND, "filter")
greed.keymap.bind({ kind = M.KIND }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
	tab = "completion-ask",
})

--- What the prompt is opened with, as `core.prompt.open` takes it.
export type Options = {
	title: string,
	text: string?,
	on_change: (text: string) -> (),
	on_submit: (text: string) -> (),
	on_cancel: () -> (),
}

--- Asks for a filter of `block` in the prompt; `tab` completes from what it
--- printed.
function M.prompt(block: Block, options: Options): greed.View
	local client = greed.client.id()
	filtering[client] = block
	local function done()
		if filtering[client] == block then
			filtering[client] = nil
		end
	end
	return core.prompt.open({
		title = options.title,
		text = options.text,
		kind = M.KIND,
		on_change = options.on_change,
		on_submit = function(text: string)
			done()
			options.on_submit(text)
		end,
		on_cancel = function()
			done()
			options.on_cancel()
		end,
	})
end

-- The key a line of indented text starts with, and how far it's indented,
-- counting a list item's `- `: `name:` or `"name":`. Nil for a blank line.
local function shape(line: string): (number?, string?)
	local spaces, rest = string.match(line, "^(%s*)(.*)$")
	if spaces == nil or rest == nil or rest == "" then
		return nil, nil
	end
	local indent = #spaces
	while string.sub(rest, 1, 2) == "- " do
		local after = string.match(string.sub(rest, 3), "^%s*(.*)$") or ""
		indent += #rest - #after
		rest = after
	end
	local key = string.match(rest, '^"([^"]+)"%s*:') or string.match(rest, '^([^:{%["]+):%s')
	key = key or string.match(rest, '^([^:{%["]+):$')
	return indent, key
end

-- Adds the fields of a JSON object to `into`, dotted inside objects.
local function fields(object: { [string]: any }, prefix: string, into: { [string]: boolean })
	for name, value in object do
		if type(name) ~= "string" then
			continue
		end
		if type(value) == "table" and next(value) ~= nil and value[1] == nil then
			fields(value, `{prefix}{name}.`, into)
		else
			into[`{prefix}{name}`] = true
		end
	end
end

--- What a filter of `block` can complete: its sections, as `.a.b`, its
--- JSON lines' fields and its table's columns, as `name=`, each with what
--- it is.
function M.words(block: Block): { { word: string, what: string } }
	local sections: { [string]: boolean } = {}
	local named: { [string]: boolean } = {}
	local above: { { indent: number, key: string } } = {}
	local count = 0
	for line in string.gmatch(block.output or "", "[^\n]+") do
		count += 1
		if count > READ then
			break
		end
		if string.sub(line, 1, 1) == "{" then
			local value = tables.json(line)
			if type(value) == "table" and value[1] == nil then
				fields(value, "", named)
			end
		end
		local indent, key = shape(line)
		if indent then
			while #above > 0 and above[#above].indent >= indent do
				table.remove(above)
			end
			if key then
				table.insert(above, { indent = indent, key = key })
				local path: { string } = {}
				for _, part in above do
					table.insert(path, part.key)
				end
				sections["." .. table.concat(path, ".")] = true
			end
		end
	end
	if block.table then
		for _, column in block.table.columns do
			named[column] = true
		end
	end
	local words: { { word: string, what: string } } = {}
	for name in named do
		table.insert(words, { word = name .. "=", what = "field" })
	end
	-- Sections only of text that nests; a flat list of `key: value` lines
	-- has nothing to keep under a key.
	local nested = false
	for path in sections do
		if string.find(path, ".", 2, true) then
			nested = true
			break
		end
	end
	if nested then
		for path in sections do
			table.insert(words, { word = path, what = "section" })
		end
	end
	table.sort(
		words,
		function(a: { word: string, what: string }, b: { word: string, what: string }): boolean
			return a.word < b.word
		end
	)
	return words
end

local function attach()
	local lsp = require("@lsp")
	lsp.completion.source(function(view: greed.View): { Item }?
		if view:buffer():kind() ~= M.KIND then
			return nil
		end
		local block = filtering[greed.client.id()]
		if block == nil then
			return {}
		end
		local before = view:buffer():slice(0, view:cursor())
		-- A regex completes nothing.
		if string.sub(before, 1, 1) == "/" then
			return {}
		end
		local from = (string.find(before, "%S*$") or #before + 1) - 1
		local typed = string.lower(string.sub(before, from + 1))
		local items, holding = {} :: { Item }, {} :: { Item }
		for _, word in M.words(block) do
			local item: Item =
				{ label = word.word, text = word.word, detail = word.what, from = from }
			table.insert(items, item)
			if string.find(string.lower(word.word), typed, 1, true) then
				table.insert(holding, item)
			end
		end
		-- Those with what's typed in them, `.con` for `.status.conditions`,
		-- rather than every loose match, when there are any.
		return if #holding > 0 then holding else items
	end, { tab = "insert" })
	lsp.completion.keys_over(M.KIND)
end

if table.find(greed.plugin.list(), "lsp") then
	attach()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		attach()
	end
end)

return M

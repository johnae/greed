-- The prompt a filter is typed in, in a block or a view showing one, and
-- what `tab` completes there from what the block printed: the sections of
-- its indented text (`.status.conditions`), the fields of its JSON lines
-- (`level=`, `HelmRelease.name=`) and its table's columns (`STATUS=`).

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local tables = require("./tables")

type Block = state.Block
type Item = core.CompletionItem

local M = {}

--- The kind of the prompt's buffer, for its keys.
M.KIND = "shell-filter-prompt"

-- How many lines of a block's output are read for what to complete.
local READ = 5000

-- How many filters are kept for each kind of command.
local RECENT = 20

-- What's being filtered, by the client typing it: the block, its prompt,
-- and how far back `up` has gone through the filters used before.
type Typing = { block: Block, view: greed.View, back: number, typed: string }
local filtering: { [number]: Typing } = {}

-- Filters used before, newest last, by the kind of command they were used
-- on, so `kubectl logs` gets its own.
local recent: { [string]: { string } } = {}

-- The kind of command `block` ran: its first two words.
local function kind_of(block: Block): string
	local first, second = string.match(block.command, "^%s*(%S+)%s*(%S*)")
	return `{first or ""} {second or ""}`
end

-- Keeps `text`, a filter used on `block`, for `up` to bring back.
local function remember(block: Block, text: string)
	if text == "" then
		return
	end
	local kind = kind_of(block)
	local list = recent[kind] or {}
	recent[kind] = list
	local at = table.find(list, text)
	if at then
		table.remove(list, at)
	end
	table.insert(list, text)
	if #list > RECENT then
		table.remove(list, 1)
	end
end

core.style.typing_kind(M.KIND)
core.style.label_kind(M.KIND, "filter")
greed.keymap.bind({ kind = M.KIND }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
	tab = "completion-ask",
	up = "shell-filter-older",
	down = "shell-filter-newer",
})

-- Puts the filter `by` steps back (or forward) from where `up` has gone
-- in the prompt; what was typed comes back past the newest.
local function step(by: number)
	local typing = filtering[greed.client.id()]
	if typing == nil or not typing.view:valid() then
		return
	end
	local list = recent[kind_of(typing.block)] or {}
	if typing.back == 0 then
		typing.typed = typing.view:buffer():text()
	end
	local back = math.clamp(typing.back + by, 0, #list)
	if back == typing.back then
		return
	end
	typing.back = back
	local text: string = if back == 0 then typing.typed else list[#list - back + 1] or ""
	local buffer = typing.view:buffer()
	buffer:edit(function(e)
		e:replace(0, buffer:len(), text)
	end)
	typing.view:set_cursor(#text)
end

greed.command({
	name = "shell-filter-older",
	doc = "Put the filter used before this one on this kind of command in the filter prompt",
	run = function()
		step(1)
	end,
})

greed.command({
	name = "shell-filter-newer",
	doc = "Put the filter used after this one on this kind of command in the filter prompt",
	run = function()
		step(-1)
	end,
})

--- What the prompt is opened with, as `core.prompt.open` takes it.
export type Options = {
	title: string,
	text: string?,
	on_change: (text: string) -> (),
	on_submit: (text: string) -> (),
	on_cancel: () -> (),
	--- How much the filter keeps, like "11 of 144 rows", shown in the
	--- title as it's typed; nil while it keeps everything.
	kept: () -> string?,
}

--- Asks for a filter of `block` in the prompt; `tab` completes from what it
--- printed, `up` brings back filters used before on the same kind of
--- command, and the title says how much the filter keeps.
function M.prompt(block: Block, options: Options): greed.View
	local client = greed.client.id()
	local typing: Typing
	local function done()
		if filtering[client] == typing then
			filtering[client] = nil
		end
	end
	-- Says where the names are: a readable log line doesn't show them.
	local title = if #M.words(block) > 0
		then `{options.title} · tab lists fields`
		else options.title
	local view: greed.View? = nil
	local function retitle()
		local kept = options.kept()
		if view and view:valid() then
			view:configure({ title = if kept then `{kept} · {title}` else title })
		end
	end
	view = core.prompt.open({
		title = title,
		text = options.text,
		kind = M.KIND,
		on_change = function(text: string)
			options.on_change(text)
			retitle()
		end,
		on_submit = function(text: string)
			done()
			remember(block, text)
			options.on_submit(text)
		end,
		on_cancel = function()
			done()
			options.on_cancel()
		end,
	})
	local opened = assert(view)
	typing = { block = block, view = opened, back = 0, typed = "" }
	filtering[client] = typing
	retitle()
	return opened
end

-- How many values of a field are shown beside it, and how long each may be.
local SAMPLES = 3
local SAMPLE_WIDTH = 20

-- Adds `value`, as a filter would match it, to the values seen of a field,
-- up to `SAMPLES` different ones.
local function sample(seen: { string }, value: any)
	if #seen >= SAMPLES or type(value) == "table" then
		return
	end
	local text = core.text.clip(tostring(value), SAMPLE_WIDTH)
	if text ~= "" and not table.find(seen, text) then
		table.insert(seen, text)
	end
end

-- Adds the fields of a JSON object to `into` with values they have, dotted
-- inside objects.
local function fields(object: { [string]: any }, prefix: string, into: { [string]: { string } })
	for name, value in object do
		if type(name) ~= "string" then
			continue
		end
		if type(value) == "table" and next(value) ~= nil and value[1] == nil then
			fields(value, `{prefix}{name}.`, into)
		else
			local key = `{prefix}{name}`
			into[key] = into[key] or {}
			sample(into[key], value)
		end
	end
end

--- What a filter of `block` can complete: its sections, as `.a.b`, its
--- JSON lines' fields and its table's columns, as `name=`, each with what
--- it is: values a field has, since a readable log line doesn't name its
--- fields (`level` or `severity`).
function M.words(block: Block): { { word: string, what: string } }
	local sections: { [string]: boolean } = {}
	local named: { [string]: { string } } = {}
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
		local indent, key = greed.text.shape(line, true)
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
	local tbl = block.table
	if tbl then
		for _, column in tbl.columns do
			local seen = named[column] or {}
			named[column] = seen
			for _, row in tbl.rows do
				if #seen >= SAMPLES then
					break
				end
				sample(seen, row[column] or "")
			end
		end
	end
	local words: { { word: string, what: string } } = {}
	for name, seen in named do
		local what = if #seen > 0 then table.concat(seen, ", ") else "field"
		table.insert(words, { word = name .. "=", what = what })
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
		local typing = filtering[greed.client.id()]
		if typing == nil then
			return {}
		end
		local block = typing.block
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

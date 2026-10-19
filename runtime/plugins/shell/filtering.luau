-- The box a filter is typed in, in a block or a view showing one: the
-- search box everything else has (`core.search_box`), whose `tab`
-- completes from what the block printed: the sections of its indented
-- text (`.status.conditions`), the fields of its JSON lines (`level=`,
-- `HelmRelease.name=`) and its table's columns (`STATUS=`).

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local tables = require("./tables")

type Block = state.Block
type Word = core.SearchBoxWord

local M = {}

-- How many lines of a block's output are read for what to complete.
local READ = 5000

-- The kind of command `block` ran: its first two words, so `kubectl
-- logs` keeps filters of its own.
local function kind_of(block: Block): string
	local first, second = string.match(block.command, "^%s*(%S+)%s*(%S*)")
	return `{first or ""} {second or ""}`
end

--- What the box is opened with.
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

--- Asks for a filter of `block` in a search box; `tab` completes from
--- what it printed, `up` brings back filters used before on the same kind
--- of command, and the title says how much the filter keeps.
function M.prompt(block: Block, options: Options): greed.View
	-- Says where the names are: a readable log line doesn't show them.
	local title = if #M.words(block) > 0
		then `{options.title} · tab lists fields`
		else options.title
	return core.search_box.open({
		title = title,
		text = options.text,
		regex = true,
		history = "shell " .. kind_of(block),
		words = function(): { Word }
			return M.words(block)
		end,
		count = function(): (number?, string?)
			return nil, options.kept()
		end,
		on_change = function(text: string)
			options.on_change(text)
		end,
		on_submit = function(text: string)
			options.on_submit(text)
		end,
		on_cancel = options.on_cancel,
	})
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
function M.words(block: Block): { Word }
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
	local words: { Word } = {}
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
	table.sort(words, function(a: Word, b: Word): boolean
		return a.word < b.word
	end)
	return words
end

return M

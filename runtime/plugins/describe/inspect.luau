-- The inspector's page for an object: its state, the objects it relates
-- to and its actions, as lines, with what each line leads to (another
-- object to inspect, or an action to run).

local greed = require("@greed")
local core = require("@core")

local M = {}

--- What a line of the page leads to: an object or an action.
export type Link = { object: core.Object?, action: string? }

-- At most this many objects show under a relation; the page says how many
-- more there are.
local MOST = 50

-- `value` in a few words: plain values as they are, a list of plain values
-- joined, anything else as JSON when it has none of the editor's handles.
local function shown(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local plain = true
	for i, item in value do
		plain = plain and type(i) == "number" and type(item) ~= "table"
	end
	if plain then
		local parts = {}
		for _, item in value do
			table.insert(parts, tostring(item))
		end
		return if #parts > 0 then table.concat(parts, ", ") else "none"
	end
	local ok, json = pcall(greed.json.encode, value)
	return if ok then json else "(a table)"
end

local function sorted_keys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- The widest of `names`, in cells, to pad a column to.
local function width(names: { string }): number
	local most = 0
	for _, name in names do
		most = math.max(most, core.text.width(name))
	end
	return most
end

local function pad(text: string, cells: number): string
	return text .. string.rep(" ", cells - core.text.width(text))
end

--- The page for `object`: its lines, and what lines lead to by number.
function M.page(object: core.Object): ({ string }, { [number]: Link })
	local lines = { `{object.label}  ({object.id})` }
	local links: { [number]: Link } = {}
	local state = core.objects.inspect(object)
	local keys = sorted_keys(state)
	if #keys > 0 then
		table.insert(lines, "")
		local cells = width(keys)
		for _, key in keys do
			table.insert(lines, `  {pad(key, cells)}  {shown(state[key])}`)
		end
	end
	local related = core.objects.related(object)
	local names = sorted_keys(related)
	if #names > 0 then
		table.insert(lines, "")
		table.insert(lines, "Related")
		local cells = width(names)
		for _, name in names do
			local list = related[name]
			if #list == 0 then
				table.insert(lines, `  {pad(name, cells)}  none`)
			end
			for i, other in list do
				if i > MOST then
					table.insert(lines, `  {pad("", cells)}  … {#list - MOST} more`)
					break
				end
				local label = if i == 1 then name else ""
				table.insert(lines, `  {pad(label, cells)}  {other.label}  ({other.id})`)
				links[#lines] = { object = other }
			end
		end
	end
	local history = core.actions.history(object.id)
	if #history > 0 then
		table.insert(lines, "")
		table.insert(lines, "Done to it")
		for i, entry in history do
			if i > MOST then
				table.insert(lines, `  … {#history - MOST} more`)
				break
			end
			local made = if entry.made then core.objects.get(entry.made) else nil
			local ago = core.time.ago((greed.now() - entry.at) // 1000)
			local what = if made then `  → {made.label}` else ""
			table.insert(lines, `  {ago}  {entry.by}  {entry.action}{what}`)
			if made then
				links[#lines] = { object = made }
			end
		end
	end
	local actions = core.objects.actions(object)
	if #actions > 0 then
		table.insert(lines, "")
		table.insert(lines, "Actions")
		local action_names = {}
		for _, action in actions do
			table.insert(action_names, action.name)
		end
		local cells = width(action_names)
		for _, action in actions do
			table.insert(lines, `  {pad(action.name, cells)}  {action.doc or ""}`)
			links[#lines] = { action = action.name }
		end
	end
	return lines, links
end

--- The page for `object` as plain text, for agents and `describe` by name.
function M.text(object: core.Object): { string }
	local lines = M.page(object)
	return lines
end

return M

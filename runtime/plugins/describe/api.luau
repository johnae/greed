-- The plugin API as the types file describes it: each function and type
-- with its signature, its doc comment and the line it's on, and the events
-- plugins can listen for with the type of what they get.

local greed = require("@greed")

local M = {}

--- A function or method (`greed.open`, `greed.option.set`, `Buffer:edit`)
--- or a type (`type Buffer`), from the types file.
export type Entry = {
	name: string,
	signature: string,
	doc: string,
	line: number,
}

--- An event from the overloads of `greed.on`, and the type its handler gets.
export type Event = {
	name: string,
	payload: string,
	line: number,
}

export type Api = {
	path: string,
	entries: { Entry },
	events: { Event },
	--- Each exported type's fields, for an event's payload.
	fields: { [string]: { Entry } },
}

--- Where the types file is: beside the default plugins.
function M.path(): string?
	local core = greed.plugin.dirs().core
	return if core then core .. "/../../types/greed/init.luau" else nil
end

local cached: Api? = nil

--- Reads the types file, once.
function M.read(): Api?
	if cached then
		return cached
	end
	local path = M.path()
	local text = path and greed.fs.read(path)
	if path == nil or text == nil then
		return nil
	end
	local lines = string.split(text, "\n")
	local api: Api = { path = path, entries = {}, events = {}, fields = {} }
	-- The module's fields that are tables of functions, e.g. `option: Options`,
	-- found first so their functions are named `greed.option.set`.
	local modules: { [string]: string } = {}
	local inside: string? = nil
	for _, line in lines do
		local name = string.match(line, "^export type (%w+) = {")
		if name then
			inside = name
		elseif line == "}" then
			inside = nil
		elseif inside == "Greed" then
			local field, kind = string.match(line, "^\t([%w_]+): (%u%w*),?$")
			if field and kind then
				modules[kind] = "greed." .. field
			end
		end
	end
	local doc: { string } = {}
	inside = nil
	for number, line in lines do
		local comment = string.match(line, "^\t?%-%-%- ?(.*)$")
		local name = string.match(line, "^export type (%w+) = ")
		if comment then
			table.insert(doc, comment)
		elseif name then
			inside = if string.find(line, "{$") then name else nil
			table.insert(api.entries, {
				name = "type " .. name,
				signature = line,
				doc = table.concat(doc, " "),
				line = number,
			})
			api.fields[name] = {}
			doc = {}
		elseif line == "}" then
			inside = nil
			doc = {}
		elseif inside then
			local field, signature = string.match(line, "^\t([%w_]+): (.*),$")
			if field and signature then
				local entry = {
					name = field,
					signature = signature,
					doc = table.concat(doc, " "),
					line = number,
				}
				table.insert(api.fields[inside], entry)
				local owner = if inside == "Greed" then "greed" else modules[inside]
				local qualified = if string.find(signature, "^%(self: ")
					then `{inside}:{field}`
					elseif owner and string.find(signature, "%->") then `{owner}.{field}`
					else nil
				if qualified then
					table.insert(api.entries, {
						name = qualified,
						signature = signature,
						doc = entry.doc,
						line = number,
					})
				end
			end
			doc = {}
		else
			doc = {}
		end
		for event, payload in string.gmatch(line, 'event: "([%w%.]+)", handler: %(event: (%w+)%)') do
			table.insert(
				api.events,
				{ name = event :: string, payload = payload :: string, line = number }
			)
		end
	end
	table.sort(api.entries, function(a: Entry, b: Entry)
		return a.name < b.name
	end)
	cached = api
	return api
end

return M

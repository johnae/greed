-- Choices in Markdown: list items starting `( )`, one of them `(x)`, under
-- a question. Pressing one (a click, or enter on it) picks it and unpicks
-- the others in its group, by editing the text, so the answer is the file:
--
--     How do you like to edit?
--
--     - (x) Helix: select first, then act
--     - ( ) Vim: say what, then where
--
-- Plugins read the answers with `list` and hear each pick with `on_pick`.
-- A choice only edits its own text; what a pick does is up to the plugin
-- that listens.

local greed = require("@greed")

local M = {}

--- One choice: its text after the box, whether it's picked, and its line
--- (0-based).
export type Option = { text: string, picked: boolean, line: number }

--- A group of choices: the question above them (the nearest line of text,
--- a heading without its hashes), and the options in order.
export type Group = { question: string?, options: { Option }, line: number }

local function text_of(buffer: greed.Buffer, line: number): string
	return buffer:slice(buffer:line_start(line), buffer:line_end(line))
end

-- A choice line's indent, box mark and text, or nil.
local function choice_of(text: string): (string?, string?, string?)
	return string.match(text, "^(%s*)[-*+] %(([ xX])%) (.*)$")
end

--- Every group of choices in `buffer`: runs of choice lines at the same
--- indent, in order.
function M.list(buffer: greed.Buffer): { Group }
	local groups: { Group } = {}
	local current: Group? = nil
	local indent: string? = nil
	for n = 0, buffer:line_count() - 1 do
		local spaces, mark, rest = choice_of(text_of(buffer, n))
		if spaces and mark and rest then
			if current == nil or spaces ~= indent then
				local question: string? = nil
				for above = n - 1, 0, -1 do
					local line = text_of(buffer, above)
					if not string.match(line, "^%s*$") then
						local words = string.match(line, "^#*%s*(.-)%s*$")
						question = if words ~= "" then words else nil
						break
					end
				end
				current = { question = question, options = {}, line = n }
				indent = spaces
				table.insert(groups, current :: Group)
			end
			table.insert(
				(current :: Group).options,
				{ text = rest, picked = mark ~= " ", line = n }
			)
		else
			current, indent = nil, nil
		end
	end
	return groups
end

--- The group whose options include `line`, if any.
function M.at(buffer: greed.Buffer, line: number): Group?
	for _, group in M.list(buffer) do
		for _, option in group.options do
			if option.line == line then
				return group
			end
		end
	end
	return nil
end

local listeners: { { hear: (buffer: greed.Buffer, group: Group) -> (), plugin: string? } } = {}

--- Calls `hear` with the buffer and the group after each pick, from
--- `plugin` if given: its listeners go when it does. Calling what it
--- returns stops it.
function M.on_pick(hear: (buffer: greed.Buffer, group: Group) -> (), plugin: string?): () -> ()
	local entry = { hear = hear, plugin = plugin }
	table.insert(listeners, entry)
	return function()
		local at = table.find(listeners, entry)
		if at then
			table.remove(listeners, at)
		end
	end
end

greed.on("plugin.unloaded", function(event)
	for i = #listeners, 1, -1 do
		if listeners[i].plugin == event.name then
			table.remove(listeners, i)
		end
	end
end)

--- Picks the choice on `line` and unpicks the rest of its group.
function M.pick(buffer: greed.Buffer, line: number)
	local group = M.at(buffer, line)
	if group == nil then
		return
	end
	buffer:edit(function(e)
		for _, option in group.options do
			local start = buffer:line_start(option.line)
			local box = string.find(text_of(buffer, option.line), "%(", 1) :: number
			e:replace(start + box, start + box + 1, if option.line == line then "x" else " ")
		end
	end)
	local picked = M.at(buffer, line) :: Group
	for _, listener in listeners do
		local ok, err = pcall(listener.hear, buffer, picked)
		if not ok then
			greed.echo(`a choice listener failed: {err}`)
		end
	end
end

greed.command({
	name = "choice-pick",
	doc = "Pick the choice under the cursor, unpicking the others in its group",
	run = function(ctx)
		local selection = ctx.view:selection()
		M.pick(ctx.buffer, ctx.buffer:line_of(selection.ranges[selection.primary].head))
	end,
})

return M

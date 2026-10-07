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
local registry = require("@core").registry
local structure = require("./structure")

local M = {}

--- One choice: its text after the box, whether it's picked, and its line
--- (0-based).
export type Option = { text: string, picked: boolean, line: number }

--- A group of choices: the question above them (the nearest line of text,
--- a heading without its hashes), and the options in order.
export type Group = { question: string?, options: { Option }, line: number }

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
	local s = structure.of(buffer)
	for i, text in s.lines do
		local n = i - 1
		local spaces, mark, rest = nil :: string?, nil :: string?, nil :: string?
		if s.item_at[n] then
			spaces, mark, rest = choice_of(text)
		end
		if spaces and mark and rest then
			if current == nil or spaces ~= indent then
				local question: string? = nil
				for above = n - 1, 0, -1 do
					local line = s.lines[above + 1]
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

local listeners: { { hear: (buffer: greed.Buffer, group: Group) -> () } } = {}

--- Calls `hear` with the buffer and the group after each pick, until the
--- plugin that called this goes or what it returns is called. A second
--- argument, once the plugin's name, is ignored.
function M.on_pick(hear: (buffer: greed.Buffer, group: Group) -> (), _plugin: string?): () -> ()
	local stop = registry.put(listeners, { hear = hear })
	greed.plugin.tie(stop)
	return stop
end

--- Picks the choice on `line` and unpicks the rest of its group.
function M.pick(buffer: greed.Buffer, line: number)
	local group = M.at(buffer, line)
	if group == nil then
		return
	end
	buffer:edit(function(e)
		for _, option in group.options do
			local start = buffer:line_start(option.line)
			local box = string.find(buffer:line_text(option.line), "%(", 1) :: number
			e:replace(start + box, start + box + 1, if option.line == line then "x" else " ")
		end
	end)
	local picked = M.at(buffer, line) :: Group
	for _, listener in listeners do
		xpcall(listener.hear, function(err)
			greed.echo(`a choice listener failed: {err}`)
		end, buffer, picked)
	end
end

greed.command({
	name = "choice-pick",
	doc = "Pick the choice under the cursor, unpicking the others in its group",
	run = function(ctx)
		M.pick(ctx.buffer, ctx.buffer:line_of(ctx.view:cursor()))
	end,
})

return M

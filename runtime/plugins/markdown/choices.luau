-- Choices in Markdown: list items starting `( )`, one of them `(x)`, under
-- a question. Pressing one (a click, or enter on it) picks it and unpicks
-- the others in its group, by editing the text, so the answer is the file:
--
--     How do you like to edit? <!-- id=style -->
--
--     - (x) Helix: select first, then act
--     - ( ) Vim: say what, then where
--
-- A comment on the question names it (`id=style`), for code to find its
-- answer. An option's value is its text up to the first ":" ("Helix"), or
-- what a `<!-- value=helix -->` comment on it says.
--
-- Plugins read the answers with `list` and hear each pick with `on_pick`.
-- A choice only edits its own text; what a pick does is up to the plugin
-- that listens.

local greed = require("@greed")
local registry = require("@core").registry
local structure = require("./structure")

local M = {}

--- One choice: its text after the box (without comments), its value,
--- whether it's picked, and its line (0-based).
export type Option = { text: string, value: string, picked: boolean, line: number }

--- A group of choices: the question above them (the nearest line of text,
--- a heading without its hashes), its name from an `id=` comment on that
--- line, and the options in order.
export type Group = { question: string?, id: string?, options: { Option }, line: number }

-- A choice line's indent, box mark and text, or nil.
local function choice_of(text: string): (string?, string?, string?)
	return string.match(text, "^(%s*)[-*+] %(([ xX])%) (.*)$")
end

--- What `key=` says in a `<!-- ... -->` comment in `text`, if one does.
function M.comment_value(text: string, key: string): string?
	for comment in string.gmatch(text, "<!%-%-(.-)%-%->") do
		local value = string.match(comment, `%f[%w_-]{key}=([^%s]+)`)
		if value then
			return value
		end
	end
	return nil
end

--- `text` without its `<!-- ... -->` comments, trimmed.
function M.without_comments(text: string): string
	return (string.match(string.gsub(text, "<!%-%-.-%-%->", ""), "^%s*(.-)%s*$") or "")
end

--- An option's value, from its text after the box: its `value=` comment, or
--- the text up to the first ":".
function M.value_of(rest: string): string
	local given = M.comment_value(rest, "value")
	if given then
		return given
	end
	local text = M.without_comments(rest)
	return string.match(text, "^%s*(.-)%s*:") or text
end

--- Every group of choices in `buffer`: runs of choice lines at the same
--- indent, in order.
function M.list(buffer: greed.Buffer): { Group }
	local groups: { Group } = {}
	local current: Group? = nil
	local indent: string? = nil
	local s = structure.of(buffer)
	-- Code between a question and its choices, like a block that makes
	-- them, is passed over looking for the question.
	local code: { [number]: boolean } = {}
	for _, block in s.code do
		for n = block.open, block.close do
			code[n] = true
		end
	end
	for i, text in s.lines do
		local n = i - 1
		local spaces, mark, rest = nil :: string?, nil :: string?, nil :: string?
		if s.item_at[n] then
			spaces, mark, rest = choice_of(text)
		end
		if spaces and mark and rest then
			if current == nil or spaces ~= indent then
				local question: string?, id: string? = nil, nil
				for above = n - 1, 0, -1 do
					local line = s.lines[above + 1]
					if not code[above] and not string.match(line, "^%s*$") then
						local words = M.without_comments(string.match(line, "^#*%s*(.-)%s*$") or "")
						question = if words ~= "" then words else nil
						id = M.comment_value(line, "id")
						break
					end
				end
				current = { question = question, id = id, options = {}, line = n }
				indent = spaces
				table.insert(groups, current :: Group)
			end
			table.insert((current :: Group).options, {
				text = M.without_comments(rest),
				value = M.value_of(rest),
				picked = mark ~= " ",
				line = n,
			})
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

--- What hears a pick: the buffer, the group as picked now, and the plugin
--- that picked it, nil when you did.
export type Hear = (buffer: greed.Buffer, group: Group, by: string?) -> ()

local listeners: { { hear: Hear } } = {}

--- Calls `hear` after each pick (see `Hear`), until the
--- plugin that called this goes or what it returns is called. A second
--- argument, once the plugin's name, is ignored.
function M.on_pick(hear: Hear, _plugin: string?): () -> ()
	local stop = registry.put(listeners, { hear = hear })
	greed.plugin.tie(stop)
	return stop
end

--- Picks the choice on `line` and unpicks the rest of its group.
function M.pick(buffer: greed.Buffer, line: number)
	-- A plugin picking for you is told to listeners, which may then do no
	-- more than that plugin may.
	local by = greed.plugin.caller()
	local group = M.at(buffer, line)
	if group == nil then
		return
	end
	-- This plugin's own handle on the buffer, so a pick goes in a read-only
	-- page too, like a page of questions: it's this plugin's edit there.
	local own = buffer
	for _, open in greed.buffers() do
		if open == buffer then
			own = open
			break
		end
	end
	own:edit(function(e)
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
		end, buffer, picked, by)
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

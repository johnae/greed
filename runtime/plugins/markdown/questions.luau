-- Questionnaires in Markdown: named choices (choices.luau) and parts of
-- the page shown only for some answers.
--
--     Will you use agents? <!-- id=agents -->
--
--     - (x) Yes
--     - ( ) No
--
--     <!-- if agents=yes -->
--     Which language model? <!-- id=provider -->
--
--     - ( ) Anthropic
--     - ( ) Ollama: on this machine
--     <!-- end -->
--
-- A condition compares a question's answer, its picked option's value,
-- ignoring case: `if agents=yes`, or `if agents!=yes`; `if style=vim,helix`
-- holds for either. Parts nest. One
-- whose condition doesn't hold is folded away when the file shows as a
-- document, and its questions don't count in `answers`. On GitHub and
-- the like, everything shows, and the comments don't.

local greed = require("@greed")
local choices = require("./choices")
local structure = require("./structure")

type Structure = structure.Structure

local M = {}

--- A part shown only for some answers: its `if` and `end` lines (0-based),
--- and the question, value and whether it's `!=` it compares.
export type Section = { open: number, close: number, id: string, value: string, negated: boolean }

-- What each structure says of its parts and answers, worked out once for
-- each version of a buffer.
type Known = {
	sections: { Section },
	hidden: { [number]: boolean }?,
	answers: { [string]: string }?,
}
local known: { [Structure]: Known } = setmetatable({}, { __mode = "k" }) :: any

--- Every conditional part of `buffer`, in order of their `if` lines. An
--- `if` without its `end` runs to the end of the file. Shared: read it,
--- don't change it.
function M.sections(buffer: greed.Buffer): { Section }
	local s = structure.of(buffer)
	local seen = known[s]
	if seen then
		return seen.sections
	end
	local found: { Section } = {}
	local open: { Section } = {}
	for _, n in s.comments do
		local line = s.lines[n + 1]
		local id, negated, value =
			string.match(line, "^%s*<!%-%-%s*if%s+([%w_-]+)%s*(!?)=%s*([^%s]+)%s*%-%->%s*$")
		if id and value then
			local section: Section = {
				open = n,
				close = #s.lines - 1,
				id = id,
				value = value,
				negated = negated == "!",
			}
			table.insert(found, section)
			table.insert(open, section)
		elseif string.match(line, "^%s*<!%-%-%s*end%s*%-%->%s*$") and #open > 0 then
			(table.remove(open) :: Section).close = n
		end
	end
	known[s] = { sections = found }
	return found
end

-- Whether `section` holds for `answers`.
local function holds(section: Section, answers: { [string]: string }): boolean
	local answer = answers[section.id]
	local same = false
	if answer ~= nil then
		for value in string.gmatch(section.value, "[^,]+") do
			same = same or string.lower(answer) == string.lower(value)
		end
	end
	return same ~= section.negated
end

--- The lines of the parts of `buffer` whose conditions don't hold for its
--- answers, and those answers: each named question's picked value, leaving
--- out questions in those parts. A part inside one that's hidden is hidden
--- too, whatever its own condition says.
function M.state(buffer: greed.Buffer): ({ [number]: boolean }, { [string]: string })
	local sections = M.sections(buffer)
	local seen = known[structure.of(buffer)]
	if seen.hidden and seen.answers then
		return seen.hidden, seen.answers
	end
	local groups = choices.list(buffer)
	local hidden: { [number]: boolean } = {}
	local answers: { [string]: string } = {}
	-- An answer can show or hide a part with another question in it, whose
	-- answer can do the same: worked out again until nothing changes.
	for _ = 1, #sections + 1 do
		local now: { [string]: string } = {}
		for _, group in groups do
			if group.id and not hidden[group.line] then
				for _, option in group.options do
					if option.picked then
						now[group.id] = option.value
					end
				end
			end
		end
		local lines: { [number]: boolean } = {}
		for _, section in sections do
			if lines[section.open] or not holds(section, now) then
				for n = section.open, section.close do
					lines[n] = true
				end
			end
		end
		local same = true
		for n in lines do
			same = same and hidden[n] == true
		end
		for n in hidden do
			same = same and lines[n] == true
		end
		hidden, answers = lines, now
		if same then
			break
		end
	end
	seen.hidden, seen.answers = hidden, answers
	return hidden, answers
end

--- Each named question's answer in `buffer`, its picked option's value,
--- leaving out questions in parts whose conditions don't hold.
function M.answers(buffer: greed.Buffer): { [string]: string }
	local _, answers = M.state(buffer)
	return answers
end

--- The marks for lines `first` to `last` of `buffer` shown as a document:
--- comments hidden, and each part whose condition doesn't hold folded
--- under its `if` line, which says when it shows. With the cursor on that
--- line the part opens, dimmed, to read and edit.
function M.marks(buffer: greed.Buffer, s: Structure, first: number, last: number): { greed.Mark }
	local hidden = M.state(buffer)
	local sections = M.sections(buffer)
	-- The `if` line of each hidden part, and the part.
	local folded: { [number]: Section } = {}
	for _, section in sections do
		if hidden[section.open] then
			folded[section.open] = section
		end
	end
	local out: { greed.Mark } = {}
	for n = first, math.min(last, #s.lines - 1) do
		local line = s.lines[n + 1]
		if not s.code_at[n] then
			local section = folded[n]
			local hint: string? = nil
			if section then
				local values = string.gsub(section.value, ",", " or ")
				local is = if section.negated then "isn't" else "is"
				hint = `▸ shows if {section.id} {is} {values}`
			end
			local at = 1
			while true do
				local from, to = string.find(line, "%s*<!%-%-.-%-%->", at)
				if from == nil or to == nil then
					break
				end
				table.insert(out, {
					from = s.starts[n + 1] + from - 1,
					to = s.starts[n + 1] + to,
					style = "markdown.marker",
					text = hint,
					conceal = true,
				})
				at = to + 1
			end
		end
	end
	for _, section in sections do
		if section.open >= first and section.open <= last and hidden[section.open] then
			-- Inside a hidden part, the outer one's fold covers it.
			local inside = false
			for _, outer in sections do
				if
					outer.open < section.open
					and outer.close >= section.close
					and hidden[outer.open]
				then
					inside = true
					break
				end
			end
			if not inside then
				table.insert(out, {
					from = s.starts[section.open + 1],
					to = buffer:line_end(section.close),
					style = "markdown.marker",
					fold = true,
					peek = true,
				})
			end
		end
	end
	return out
end

return M

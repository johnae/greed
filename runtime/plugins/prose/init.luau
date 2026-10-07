-- Text objects for prose: select or move by sentence, paragraph and
-- Markdown section.
--
--   m i p / m a p   select the paragraph (a: with the blank lines after it)
--   m i s / m a s   select the sentence (a: with the spaces after it)
--   m i h / m a h   select the section under a heading (a: with the heading)
--   ] p / [ p       next / previous paragraph
--   ] s / [ s       next / previous sentence

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")

type Buffer = greed.Buffer
type Range = greed.Range

local each_range, point = core.motions.each_range, core.motions.point

-- Where `line` ends, including its line break.
local function after_line(buffer: Buffer, line: number): number
	if line + 1 < buffer:line_count() then
		return buffer:line_start(line + 1)
	end
	return buffer:len()
end

local blank, paragraph = core.objects.blank, core.objects.paragraph

-- Selects `core.objects.find`'s object for `key` at the selection's head.
local function object(key: string): (Buffer, Range, boolean) -> Range
	return function(buffer, range, around)
		local from, to = core.objects.find(buffer, range.head, key, around)
		return if from and to then { anchor = from, head = to } else range
	end
end

-- Heading levels by line, leaving out lines in code blocks.
local function headings(buffer: Buffer): { [number]: number }
	local found = {}
	for _, heading in markdown.structure(buffer).headings do
		found[heading.line] = heading.level
	end
	return found
end

local function select_section(buffer: Buffer, range: Range, around: boolean): Range
	local levels = headings(buffer)
	local heading = buffer:line_of(range.head)
	while heading > 0 and levels[heading] == nil do
		heading -= 1
	end
	local level = levels[heading]
	local stop = buffer:len()
	for line = heading + 1, buffer:line_count() - 1 do
		local other = levels[line]
		-- With no heading above, the section ends at the first one.
		if other and (level == nil or other <= level) then
			stop = buffer:line_start(line)
			break
		end
	end
	local start = if around or level == nil
		then buffer:line_start(heading)
		else after_line(buffer, heading)
	return { anchor = start, head = stop }
end

local function next_paragraph(buffer: Buffer, head: number): number
	local _, last = paragraph(buffer, buffer:line_of(head))
	local line = last + 1
	while line < buffer:line_count() and blank(buffer, line) do
		line += 1
	end
	return if line < buffer:line_count() then buffer:line_start(line) else buffer:len()
end

local function prev_paragraph(buffer: Buffer, head: number): number
	local line = buffer:line_of(head)
	local first = paragraph(buffer, line)
	if buffer:line_start(first) < head and not blank(buffer, line) then
		return buffer:line_start(first)
	end
	line = first - 1
	while line > 0 and blank(buffer, line) do
		line -= 1
	end
	return buffer:line_start((paragraph(buffer, math.max(line, 0))))
end

local function next_sentence(buffer: Buffer, head: number): number
	local _, pos = buffer:sentence(head)
	while pos < buffer:len() and string.match(buffer:char_at(pos) or "", "%s") do
		pos = buffer:next_char(pos)
	end
	return pos
end

local function prev_sentence(buffer: Buffer, head: number): number
	local from = buffer:sentence(head)
	if from < head then
		return from
	end
	local pos = from
	while pos > 0 and string.match(buffer:char_at(buffer:prev_char(pos)) or "", "%s") do
		pos = buffer:prev_char(pos)
	end
	if pos == 0 then
		return 0
	end
	return (buffer:sentence(buffer:prev_char(pos)))
end

-- Registers "select-NAME" and "select-NAME-around".
local function text_object(
	name: string,
	doc: string,
	around_doc: string,
	select: (Buffer, Range, boolean) -> Range
)
	for _, around in { false, true } do
		greed.command({
			name = if around then `select-{name}-around` else `select-{name}`,
			doc = if around then around_doc else doc,
			run = function(ctx)
				each_range(ctx, function(buffer, range)
					return select(buffer, range, around)
				end)
			end,
		})
	end
end

local function motion(name: string, doc: string, target: (Buffer, number) -> number)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			each_range(ctx, function(buffer, range)
				return point(target(buffer, range.head))
			end)
		end,
	})
end

text_object(
	"paragraph",
	"Select the paragraph",
	"Select the paragraph and the blank lines after it",
	object("p")
)
text_object(
	"sentence",
	"Select the sentence",
	"Select the sentence and the spaces after it",
	object("s")
)
text_object(
	"section",
	"Select the text under the Markdown heading",
	"Select the Markdown section, heading included",
	select_section
)
motion("next-paragraph", "Move to the start of the next paragraph", next_paragraph)
motion("prev-paragraph", "Move to the start of the paragraph, or the one before", prev_paragraph)
motion("next-sentence", "Move to the start of the next sentence", next_sentence)
motion("prev-sentence", "Move to the start of the sentence, or the one before", prev_sentence)

greed.keymap.bind({ role = "command" }, {
	["] p"] = "next-paragraph",
	["[ p"] = "prev-paragraph",
	["] s"] = "next-sentence",
	["[ s"] = "prev-sentence",
})
-- Helix's text object keys for them.
greed.keymap.bind({ style = "helix", role = "command" }, {
	["m i p"] = "select-paragraph",
	["m a p"] = "select-paragraph-around",
	["m i s"] = "select-sentence",
	["m a s"] = "select-sentence-around",
	["m i h"] = "select-section",
	["m a h"] = "select-section-around",
})

-- A board's file: Markdown, its `# ` heading the board's title, `## `
-- headings its sections, and each shell code block a card, the command to
-- run with options after the language:
--
--     ```sh every=5 title="pods" height=10
--     kubectl get pods -n payments
--     ```
--
-- `every=SECONDS` runs it again that often (`live` every two seconds);
-- without either it runs once, and again when the board refreshes, or as
-- long as it runs by itself (`kubectl get pods -w`). `title` names the
-- card, `height` is how many lines of it show (10), `span` how many
-- columns of the board it takes (`wide` the whole row), `chart` draws it
-- as a chart (`chart="bar CPU"` says which), and `dir` is the folder it
-- runs in, from the project's root.

local blocks = require("@blocks")
local shell = require("@shell")

local M = {}

--- A card: the command it runs and how it shows.
export type Card = {
	command: string,
	title: string,
	--- Seconds between runs; nil to run once.
	every: number?,
	height: number,
	dir: string?,
	--- How many columns of the board it takes; 0 for the whole row.
	span: number,
	--- What `chart` is given, to draw it as a chart; "" to guess.
	chart: string?,
	--- The `## ` heading it's under.
	section: string?,
	--- The lines of the file it's on, from its opening fence to its
	--- closing one, from 1.
	first: number,
	last: number,
}

--- A board as its file says: its title and its cards, in order.
export type Parsed = { title: string?, cards: { Card } }

-- The languages a card's command may be written as.
local SHELLS: { [string]: boolean } =
	{ sh = true, shell = true, bash = true, zsh = true, fish = true, nu = true, console = true }

local HEIGHT = 10

-- A card's title when it has none: its command's first line, cut short.
local function title_of(command: string): string
	local first = string.match(command, "^[^\n]*") or command
	return if #first > 40 then string.sub(first, 1, 39) .. "…" else first
end

-- Whether `info` has `word` on its own, as `live` or `wide`.
local function has(info: string, word: string): boolean
	return string.find(` {info} `, `%s{word}%s`) ~= nil
end

-- The card a code block with info string `info` and code `code` is, under
-- `section`; nil for one that isn't a shell's.
local function card_of(info: string, code: string, section: string?): Card?
	local lang, opts = blocks.parse.info(info)
	local command = string.match(code, "^%s*(.-)%s*$") or ""
	if not SHELLS[lang] or command == "" then
		return nil
	end
	local every = tonumber(opts.every)
	if every == nil and has(info, "live") then
		every = 2
	end
	return {
		command = command,
		title = opts.title or title_of(command),
		every = if every then math.max(every, 0.5) else nil,
		height = math.max(tonumber(opts.height) or HEIGHT, 1),
		dir = opts.dir,
		span = if has(info, "wide") then 0 else math.max(tonumber(opts.span) or 1, 1),
		chart = opts.chart or (if has(info, "chart") then "" else nil),
		section = section,
		first = 0,
		last = 0,
	}
end

--- Reads a board's file, `text`.
function M.parse(text: string): Parsed
	local parsed: Parsed = { title = nil, cards = {} }
	local section: string? = nil
	local fence: string? = nil
	local info = ""
	local code: { string } = {}
	local opened = 0
	for n, line in string.split(string.gsub(text, "\r", ""), "\n") do
		local open = fence
		if open then
			if string.match(line, "^%s*" .. open .. "%s*$") then
				local card = card_of(info, table.concat(code, "\n"), section)
				if card then
					card.first, card.last = opened, n
					table.insert(parsed.cards, card)
				end
				fence = nil
			else
				table.insert(code, line)
			end
			continue
		end
		local ticks, rest = string.match(line, "^%s*(```+)(.*)$")
		if ticks == nil then
			ticks, rest = string.match(line, "^%s*(~~~+)(.*)$")
		end
		if ticks and rest then
			fence, info, code, opened = ticks, rest, {}, n
		elseif string.match(line, "^##%s") then
			section = string.match(line, "^##%s+(.-)%s*$")
		elseif string.match(line, "^#%s") and parsed.title == nil then
			parsed.title = string.match(line, "^#%s+(.-)%s*$")
		end
	end
	return parsed
end

-- `text` quoted for an info string when it has spaces or quotes.
local function value(text: string): string
	if string.find(text, '[%s"]') then
		return '"' .. string.gsub(text, '"', "'") .. '"'
	end
	return text
end

--- The text of a card for a board's file: a shell code block running
--- `command`, with `every`, `title` and `dir` when given.
function M.card_text(
	command: string,
	opts: { every: number?, title: string?, dir: string? }
): string
	local info = "sh"
	if opts.every then
		info ..= ` every={opts.every}`
	end
	if opts.title then
		info ..= ` title={value(opts.title)}`
	end
	if opts.dir then
		info ..= ` dir={value(opts.dir)}`
	end
	return `\`\`\`{info}\n{command}\n\`\`\`\n`
end

--- `text`, a board's file, with its cards `a` and `b` (`a` the earlier)
--- swapped, each with its options.
function M.swap(text: string, a: Card, b: Card): string
	local lines = string.split(text, "\n")
	local out: { string } = {}
	local function copy(from: number, to: number)
		table.move(lines, from, to, #out + 1, out)
	end
	copy(1, a.first - 1)
	copy(b.first, b.last)
	copy(a.last + 1, b.first - 1)
	copy(a.first, a.last)
	copy(b.last + 1, #lines)
	return table.concat(out, "\n")
end

--- `command` as a card runs it: what it runs each time, and how often,
--- when it's a `watch` (`watch -n 5 kubectl get pods`).
function M.unwatched(command: string): (string, number?)
	local line, every = shell.live.read(command)
	if line then
		return line, every
	end
	return command, nil
end

return M

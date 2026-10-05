-- Markdown as a document: headings without their hashes (the top level
-- twice the size), **bold**, *italic*, ~~struck~~ and `code` without their
-- markers, links as their text, fenced code on a background of its own,
-- quotes with a bar, `---` as a line and list dashes as bullets. The file
-- stays plain Markdown: typing on a line shows it as written (see
-- `core.reveal`). Turn it off with `:set markdown-look false`. `tab` folds
-- the section, list item or code block around the cursor (folds.luau).
--
-- Other plugins can draw some parts their own way: notes draws headings and
-- bullets as symbols, and claims them with `require("@markdown").claim`.

local greed = require("@greed")
local core = require("@core")
require("@self/folds")

local M = {}

greed.option.define({
	name = "markdown-look",
	doc = "Show Markdown with its markup hidden and its headings, code and quotes drawn as such",
	default = true,
})

--- What another plugin draws its own way in a buffer: "headings",
--- "bullets".
export type Parts = { [string]: boolean }

local claims: { (buffer: greed.Buffer) -> Parts? } = {}

-- What others claimed in `buffer`.
local function claimed(buffer: greed.Buffer): Parts
	local parts: Parts = {}
	for _, claim in claims do
		for part, yes in claim(buffer) or {} do
			parts[part] = parts[part] or yes
		end
	end
	return parts
end

-- A line's text from `at` and the marks it gets, with what's taken by code
-- spans and links so other markup isn't looked for inside them.
type Line = {
	text: string,
	at: number,
	out: { greed.Mark },
	shows: "line" | "cursor" | "never",
	taken: { { number } },
}

-- Hides `text`'s bytes `from` to `to` (1-based, inclusive), showing
-- `replacement` in their place if given.
local function hide(line: Line, from: number, to: number, replacement: string?, style: string?)
	table.insert(line.out, {
		from = line.at + from - 1,
		to = line.at + to,
		style = style or "markdown.marker",
		text = replacement,
		conceal = true,
		reveal = line.shows,
	})
end

local function paint(line: Line, from: number, to: number, style: string, scale: number?)
	if to >= from then
		table.insert(
			line.out,
			{ from = line.at + from - 1, to = line.at + to, style = style, scale = scale }
		)
	end
end

local function free(line: Line, from: number, to: number): boolean
	for _, span in line.taken do
		if from <= span[2] and to >= span[1] then
			return false
		end
	end
	return true
end

-- Inline markup in `line`: code spans first, then links, then emphasis.
local function inline(line: Line)
	local text = line.text
	for from, to in string.gmatch(text, "()`[^`]+`()") do
		local first, last = from :: number, (to :: number) - 1
		hide(line, first, first)
		paint(line, first + 1, last - 1, "markdown.code")
		hide(line, last, last)
		table.insert(line.taken, { first, last })
	end
	for from, label, to in string.gmatch(text, "()%[([^%]]+)%]%([^%)]*%)()") do
		local first, last = from :: number, (to :: number) - 1
		if free(line, first, last) then
			local label_end = first + #(label :: string)
			hide(line, first, first)
			paint(line, first + 1, label_end, "markdown.link")
			hide(line, label_end + 1, last)
			table.insert(line.taken, { first, last })
		end
	end
	-- Longest markers first, so ** isn't read as two *.
	for _, kind in
		{
			{ "%*%*", 2, "markdown.bold" },
			{ "__", 2, "markdown.bold" },
			{ "~~", 2, "markdown.strike" },
			{ "%*", 1, "markdown.italic" },
			{ "_", 1, "markdown.italic" },
		}
	do
		local marker, size, style = kind[1] :: string, kind[2] :: number, kind[3] :: string
		local pattern = `(){marker}([^%s].-){marker}()`
		local start = 1
		while true do
			local from, inner, to = string.match(string.sub(text, start), pattern)
			if from == nil then
				break
			end
			local first = start + (tonumber(from) :: number) - 1
			local last = start + (tonumber(to) :: number) - 2
			local body = inner :: string
			-- `_` inside words (snake_case) isn't emphasis.
			local word = marker == "_"
				and string.match(string.sub(text, first - 1, first - 1), "%w") ~= nil
			if free(line, first, last) and not word and not string.match(body, "%s$") then
				hide(line, first, first + size - 1)
				paint(line, first + size, last - size, style)
				hide(line, last - size + 1, last)
				table.insert(line.taken, { first, last })
				start = last + 1
			else
				-- Not this one: look again from just after where it began.
				start = first + 1
			end
		end
	end
end

-- The marks for `buffer`.
local function marks(buffer: greed.Buffer): { greed.Mark }
	local out: { greed.Mark } = {}
	local parts = claimed(buffer)
	local shows = core.reveal()
	local fence: string? = nil
	-- What code blocks look like: a block's output (```` ```result ````) a
	-- little apart from code.
	local block_style = "markdown.code.block"
	for n = 0, buffer:line_count() - 1 do
		local at = buffer:line_start(n)
		local text = buffer:slice(at, buffer:line_end(n))
		local line: Line = { text = text, at = at, out = out, shows = shows, taken = {} }
		local ticks = string.match(text, "^%s*(```+)") or string.match(text, "^%s*(~~~+)")
		if fence == nil and ticks then
			block_style = if string.match(text, "^%s*[`~]+%s*result")
				then "markdown.code.block.result"
				else "markdown.code.block"
		end
		if fence or ticks then
			table.insert(out, { from = at, to = at + #text, style = block_style, line = true })
			if fence == nil then
				fence = ticks
				paint(line, 1, #text, "markdown.fence")
			elseif
				ticks
				and string.sub(ticks, 1, 1) == string.sub(fence, 1, 1)
				and #ticks >= #fence
			then
				paint(line, 1, #text, "markdown.fence")
				fence = nil
			end
			continue
		end
		-- Outside code, text is prose: in the window, in the prose font.
		paint(line, 1, #text, "markdown.text")
		local hashes, space = string.match(text, "^(#+)()%s")
		local quote = string.match(text, "^%s*>%s?()")
		local bullet = string.match(text, "^%s*()[-*+]%s")
		if
			string.match(text, "^%s*([-*_])%s*%1%s*%1[%s%-*_]*$") and not string.match(text, "%w")
		then
			hide(line, 1, #text, string.rep("─", 40), "markdown.rule")
			continue
		elseif hashes and #hashes <= 6 and not parts.headings then
			local level = #hashes
			hide(line, 1, space :: number)
			paint(
				line,
				(space :: number) + 1,
				#text,
				`markdown.heading.{level}`,
				if level == 1 then 2 else nil
			)
		elseif quote then
			hide(line, 1, (quote :: number) - 1, "▎ ", "markdown.quote.bar")
			paint(line, quote :: number, #text, "markdown.quote")
		elseif bullet and not parts.bullets then
			hide(line, bullet :: number, (bullet :: number) + 1, "• ", "markdown.bullet")
		end
		inline(line)
	end
	return out
end

local function draw(buffer: greed.Buffer)
	local ok, language = pcall(buffer.language, buffer)
	if not ok or language ~= "markdown" or greed.option.get("markdown-look") ~= true then
		pcall(buffer.decorate, buffer, "markdown", {})
		return
	end
	buffer:decorate("markdown", marks(buffer))
end

--- Draws every Markdown buffer again.
function M.refresh()
	for _, buffer in greed.buffers() do
		draw(buffer)
	end
end

--- Lets `claim` say, for each buffer, which parts it draws its own way;
--- Markdown leaves those alone there. Returns a function that undoes it.
function M.claim(claim: (buffer: greed.Buffer) -> Parts?): () -> ()
	table.insert(claims, claim)
	M.refresh()
	return function()
		local at = table.find(claims, claim)
		if at then
			table.remove(claims, at)
			M.refresh()
		end
	end
end

local function on_buffer(event: greed.BufferChanged)
	draw(event.buffer)
end

greed.on("buffer.opened", on_buffer)
greed.on("buffer.changed", on_buffer)
-- Typing shows markup as written, so it's drawn again as modes change.
greed.on("mode.changed", M.refresh)
greed.on("option.changed", function(event)
	if event.name == "markdown-look" then
		M.refresh()
	end
end)

return M

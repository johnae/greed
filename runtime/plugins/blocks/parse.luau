-- Finding the fenced blocks in a Markdown buffer: what each runs as, its
-- options, its code, and the result saved under it. Also the front matter,
-- the `---` lines at the top of a file.

local greed = require("@greed")

local M = {}

--- A fenced block, ```` ```sh id=files ```` to its closing fence. Lines are
--- 0-based; `from` and `to` are the bytes from its opening fence's start to
--- its closing fence's end, and `code_from` to `code_to` its code.
export type Block = {
	lang: string,
	info: string,
	opts: { [string]: string },
	open: number,
	close: number,
	from: number,
	to: number,
	code_from: number,
	code_to: number,
	--- The result block under it, if there's one: from the end of this
	--- block's closing fence (so the line breaks between them are in it) to
	--- the end of the result's closing fence, and the result's text.
	result: { from: number, to: number, text: string, info: string }?,
}

-- A fence line's ticks (or tildes) and what follows them.
local function fence(text: string): (string?, string)
	local ticks, rest = string.match(text, "^%s*(```+)(.*)$")
	if ticks == nil then
		ticks, rest = string.match(text, "^%s*(~~~+)(.*)$")
	end
	return ticks, rest or ""
end

--- An info string's language and options: `sh id=files dir="a b"` is "sh"
--- and `{ id = "files", dir = "a b" }`.
function M.info(info: string): (string, { [string]: string })
	local lang = string.match(info, "^%s*([^%s]+)") or ""
	local opts: { [string]: string } = {}
	local rest = string.match(info, "^%s*[^%s]+(.*)$") or ""
	for key, quoted, plain in string.gmatch(rest, '([%w_-]+)=(%b"")([^%s]*)') do
		opts[key] = string.sub(quoted :: string, 2, -2) .. (plain or "")
	end
	for key, value in string.gmatch(rest, '([%w_-]+)=([^%s"][^%s]*)') do
		if opts[key] == nil and value then
			opts[key] = value
		end
	end
	return lang, opts
end

--- Every closed fenced block in `buffer`, in order. A block right under
--- another whose language is `result` is that block's result, and isn't
--- listed on its own.
function M.blocks(buffer: greed.Buffer): { Block }
	local blocks: { Block } = {}
	local lines = buffer:line_count()
	local function line(n: number): string
		return buffer:line_text(n)
	end
	-- The closing fence for one opened by `ticks` on line `open`.
	local function closing(open: number, ticks: string): number?
		for n = open + 1, lines - 1 do
			local found, rest = fence(line(n))
			if
				found
				and string.sub(found, 1, 1) == string.sub(ticks, 1, 1)
				and #found >= #ticks
				and string.match(rest, "^%s*$")
			then
				return n
			end
		end
		return nil
	end
	local n = 0
	while n < lines do
		local ticks, info = fence(line(n))
		local close = ticks and closing(n, ticks :: string)
		if ticks == nil or close == nil then
			n += 1
			continue
		end
		local lang, opts = M.info(info)
		local block: Block = {
			lang = lang,
			info = info,
			opts = opts,
			open = n,
			close = close,
			from = buffer:line_start(n),
			to = buffer:line_end(close),
			code_from = buffer:line_start(n + 1),
			code_to = if close > n + 1
				then buffer:line_end(close - 1)
				else buffer:line_start(close),
		}
		n = close + 1
		-- Its result: a `result` block on the next line, or after one blank line.
		local at = if n < lines and string.match(line(n), "^%s*$") then n + 1 else n
		local result_ticks, result_info = nil, ""
		if at < lines then
			result_ticks, result_info = fence(line(at))
		end
		local result_close = result_ticks and closing(at, result_ticks :: string)
		if result_close and string.match(result_info, "^%s*result") then
			block.result = {
				from = block.to,
				to = buffer:line_end(result_close),
				text = if result_close > at + 1
					then buffer:slice(buffer:line_start(at + 1), buffer:line_end(result_close - 1))
					else "",
				info = result_info,
			}
			n = result_close + 1
		end
		table.insert(blocks, block)
	end
	return blocks
end

--- What the front matter's `greed:` line says, e.g. "run" for
--- `greed: run`, or nil without one.
function M.front_matter(buffer: greed.Buffer): string?
	if buffer:line_count() < 2 then
		return nil
	end
	if not string.match(buffer:line_text(0), "^%-%-%-%s*$") then
		return nil
	end
	for n = 1, math.min(buffer:line_count() - 1, 50) do
		local text = buffer:line_text(n)
		if string.match(text, "^%-%-%-%s*$") then
			return nil
		end
		local value = string.match(text, "^greed:%s*(.-)%s*$")
		if value then
			return value
		end
	end
	return nil
end

return M

-- Finding the fenced blocks in a Markdown buffer: what each runs as, its
-- options, its code, and the result saved under it. Also the front matter,
-- the `---` lines at the top of a file.

local greed = require("@greed")
local markdown = require("@markdown")

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
	local s = markdown.structure(buffer)
	local blocks: { Block } = {}
	local i = 1
	while i <= #s.code do
		local code = s.code[i]
		i += 1
		if not code.closed then
			continue
		end
		local lang, opts = M.info(code.info)
		local block: Block = {
			lang = lang,
			info = code.info,
			opts = opts,
			open = code.open,
			close = code.close,
			from = s.starts[code.open + 1],
			to = code.to,
			code_from = code.code_from,
			code_to = code.code_to,
		}
		-- Its result: a `result` block on the next line, or after one blank line.
		local after = s.code[i]
		local gap = if after then after.open - code.close else 0
		if
			after
			and after.closed
			and string.find(after.info, "^result")
			and (gap == 1 or (gap == 2 and string.find(s.lines[code.close + 2], "^%s*$")))
		then
			block.result = {
				from = block.to,
				to = after.to,
				text = buffer:slice(after.code_from, after.code_to),
				info = after.info,
			}
			i += 1
		end
		table.insert(blocks, block)
	end
	return blocks
end

--- What the front matter's `greed:` line says, e.g. "run" for
--- `greed: run`, or nil without one.
function M.front_matter(buffer: greed.Buffer): string?
	local s = markdown.structure(buffer)
	local front = s.front
	if front == nil then
		return nil
	end
	-- `s.lines` is 1-based, so the lines between the fences are 2 to `front`.
	for n = 2, front do
		local value = string.match(s.lines[n], "^greed:%s*(.-)%s*$")
		if value then
			return value
		end
	end
	return nil
end

return M

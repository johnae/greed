-- Running Luau from any buffer: `space l e` runs the selection, or the
-- line the cursor is on, in the same place `:lua` does (its globals last),
-- and shows what it returned at the end of its last line, or the error.
-- The result goes when the buffer changes.
local greed = require("@greed")
local core = require("@core")

local M = {}

-- The buffers showing a result, so the next edit can take it away.
local showing: { [number]: boolean } = {}

--- Runs `code` and shows the result in `buffer` after the line `line`
--- (0-based). Returns whether it ran and what it returned or the error.
function M.show(buffer: greed.Buffer, line: number, code: string): (boolean, string)
	local ok, result = greed.eval(code)
	local shown = if result == "" then "nil" else string.gsub(result, "\n", " ⏎ ")
	local stop = buffer:line_end(line)
	buffer:decorate("eval", {
		{
			from = stop,
			to = stop,
			style = if ok then "comment" else "diagnostic.error",
			text = if ok then `  ⇒ {shown}` else `  ✗ {shown}`,
			eol = true,
		},
	})
	showing[buffer:id()] = true
	return ok, result
end

greed.command({
	name = "eval-selection",
	doc = "Run the selected Luau, or the line, and show what it returns at the end of it",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local selection = view:selection()
		local range = selection.ranges[selection.primary]
		local from, to = core.text.span(range)
		local code: string
		local line: number
		-- A cursor alone is one character: then the whole line runs.
		if to - from <= 1 then
			line = buffer:line_of(range.head)
			code = buffer:line_text(line)
		else
			code = buffer:slice(from, to)
			line = buffer:line_of(to - 1)
		end
		M.show(buffer, line, code)
	end,
})

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if showing[buffer:id()] then
		showing[buffer:id()] = nil
		buffer:decorate("eval", {})
	end
end)

greed.keymap.bind("helix", { ["space l e"] = "eval-selection" })

return M

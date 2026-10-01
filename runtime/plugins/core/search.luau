-- Search, like Helix: / and ? search forward and back as you type, n and N
-- go to the next and previous match, and * searches for the selection.
-- Patterns are regexes; ones in lowercase ignore case.

local kern = require("@kern")
local prompt = require("./prompt")

-- The last pattern searched for, and which way.
local last: string? = nil
local backward = false

local function primary(view: kern.View): kern.Range
	local selection = view:selection()
	return selection.ranges[selection.primary]
end

local function span(range: kern.Range): (number, number)
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

-- Lowercase patterns ignore case, like Helix's smart case.
local function smart_case(pattern: string): string
	return if string.find(pattern, "%u") then pattern else "(?i)" .. pattern
end

-- Where a search for the next match starts: after the selection, or after
-- the character under a cursor.
local function after(buffer: kern.Buffer, range: kern.Range): number
	local from, to = span(range)
	return if to > from then to else buffer:next_char(from)
end

-- Selects the match of `pattern` after `range` (or before it, going back),
-- round the ends. Returns whether there was one.
local function jump(view: kern.View, pattern: string, range: kern.Range, back: boolean): boolean
	local buffer = view:buffer()
	local start = if back then span(range) else after(buffer, range)
	local from, to = buffer:find(smart_case(pattern), start, { backward = back, wrap = true })
	if from then
		view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
		return true
	end
	return false
end

local function highlight(buffer: kern.Buffer, pattern: string)
	local marks: { kern.Mark } = {}
	if pattern ~= "" then
		for _, m in buffer:find_all(smart_case(pattern)) or {} do
			if m.to > m.from then
				table.insert(marks, { from = m.from, to = m.to, style = "ui.search.match" })
			end
		end
	end
	buffer:decorate("search", marks)
end

local function search(ctx: kern.Context, back: boolean)
	local view, buffer = ctx.view, ctx.buffer
	local origin = view:selection()
	local start = primary(view)
	prompt.open({
		title = if back then "search back" else "search",
		on_change = function(pattern)
			highlight(buffer, pattern)
			view:set_selection(origin)
			if pattern ~= "" then
				jump(view, pattern, start, back)
			end
		end,
		on_submit = function(pattern)
			buffer:decorate("search", {})
			if pattern == "" then
				return
			end
			-- Nil and the error for a bad pattern.
			local found, err = buffer:find(smart_case(pattern))
			if found == nil and err then
				kern.echo(`bad pattern {pattern}: {err}`)
				return
			end
			last, backward = pattern, back
			if found == nil then
				kern.echo(`no match for {pattern}`)
			end
		end,
		on_cancel = function()
			buffer:decorate("search", {})
			view:set_selection(origin)
		end,
	})
end

-- Goes to the next match of the last search, the same way it went (or the
-- other way, with `reverse`).
local function again(ctx: kern.Context, reverse: boolean)
	if last == nil then
		kern.echo("nothing searched for yet")
		return
	end
	if not jump(ctx.view, last, primary(ctx.view), backward ~= reverse) then
		kern.echo(`no match for {last}`)
	end
end

kern.command({
	name = "search",
	doc = "Search forward for a regex as you type",
	run = function(ctx)
		search(ctx, false)
	end,
})

kern.command({
	name = "search-back",
	doc = "Search backward for a regex as you type",
	run = function(ctx)
		search(ctx, true)
	end,
})

kern.command({
	name = "search-next",
	doc = "Select the next match of the last search",
	run = function(ctx)
		again(ctx, false)
	end,
})

kern.command({
	name = "search-prev",
	doc = "Select the previous match of the last search",
	run = function(ctx)
		again(ctx, true)
	end,
})

kern.command({
	name = "search-selection",
	doc = "Search for the selected text",
	run = function(ctx)
		local text = ctx.buffer:slice(span(primary(ctx.view)))
		if text == "" then
			kern.echo("nothing selected to search for")
			return
		end
		-- As plain text, not a regex, and in the same case.
		last, backward =
			"(?-i)" .. (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0")), false
		kern.echo(`searching for {text}`)
	end,
})

return {
	smart_case = smart_case,
}

-- Helix's goto keys that aren't motions: the next and previous buffer, the
-- file you were in before (g a) and the last one you changed (g m), the
-- last change (g .), a column (g |) and the file named under the cursor
-- (g f).

local greed = require("@greed")
local motions = require("./motions")
local text = require("./text")
local project = require("./project")

local M = {}

-- File buffers, oldest first, as `greed.buffers()` lists them.
local function files(): { greed.Buffer }
	local out = {}
	for _, buffer in greed.buffers() do
		if buffer:kind() == "file" then
			table.insert(out, buffer)
		end
	end
	return out
end

-- The file buffers shown in the main view, most recent last, and the last
-- one changed.
local recent: { number } = {}
local changed: number? = nil

local function seen(buffer: greed.Buffer)
	if buffer:kind() ~= "file" then
		return
	end
	local id = buffer:id()
	if recent[#recent] ~= id then
		local at = table.find(recent, id)
		if at then
			table.remove(recent, at)
		end
		table.insert(recent, id)
	end
end

greed.on("selection.changed", function(event: greed.SelectionChanged)
	if event.view == greed.view() then
		seen(event.view:buffer())
	end
end)
greed.on("view.focused", function(event: greed.ViewFocused)
	seen(event.view:buffer())
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	if event.buffer:kind() == "file" then
		changed = event.buffer:id()
	end
end)

local function by_id(id: number?): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:id() == id then
			return buffer
		end
	end
	return nil
end

local function show(view: greed.View, buffer: greed.Buffer?)
	if buffer and buffer ~= view:buffer() then
		view:show(buffer)
		seen(buffer)
	end
end

for _, back in { false, true } do
	greed.command({
		name = if back then "buffer-prev" else "buffer-next",
		doc = if back then "Show the previous open file" else "Show the next open file",
		run = function(ctx)
			local list = files()
			if #list == 0 then
				return
			end
			local at = 0
			for i, buffer in list do
				if buffer == ctx.buffer then
					at = i
				end
			end
			local step = (ctx.count or 1) * (if back then -1 else 1)
			show(ctx.view, list[(at - 1 + step) % #list + 1])
		end,
	})
end

greed.command({
	name = "goto-last-accessed-file",
	doc = "Show the file you were in before this one",
	run = function(ctx)
		seen(ctx.buffer)
		show(ctx.view, by_id(recent[#recent - 1]))
	end,
})

greed.command({
	name = "goto-last-modified-file",
	doc = "Show the file you changed last, other than this one",
	run = function(ctx)
		show(ctx.view, by_id(changed))
	end,
})

greed.command({
	name = "goto-last-modification",
	doc = "Move to where this file was last changed",
	run = function(ctx)
		local last = ctx.buffer:history({ limit = 1 })[1]
		local change = last and last.changes[#last.changes]
		if change then
			local at = math.min(change.from + #change.text, ctx.buffer:len())
			ctx.view:set_cursor(at)
		end
	end,
})

greed.command({
	name = "goto-column",
	doc = "Move to the column given as a count, on each cursor's line",
	run = function(ctx)
		local column = (ctx.count or 1) - 1
		motions.each_range(ctx, function(buffer, range)
			local line = buffer:line_of(motions.cursor(buffer, range))
			return motions.point(text.at_column(buffer, line, column))
		end)
	end,
})

-- Characters that make up a path under the cursor.
local PATH_CHAR = "[%w%._%-/~+@]"

--- The path `range` names: the selection's text when it's longer than a
--- character, otherwise the run of path characters around the cursor. Nil
--- if there's none.
function M.path_at(buffer: greed.Buffer, range: greed.Range): string?
	local from, to = text.span(range)
	if to > buffer:next_char(from) then
		return buffer:slice(from, to)
	end
	local cursor = motions.cursor(buffer, range)
	local line = buffer:line_of(cursor)
	local start = buffer:line_start(line)
	local row = buffer:line_text(line)
	local at = cursor - start + 1
	local first, last = at, at - 1
	while first > 1 and string.match(string.sub(row, first - 1, first - 1), PATH_CHAR) do
		first -= 1
	end
	while last < #row and string.match(string.sub(row, last + 1, last + 1), PATH_CHAR) do
		last += 1
	end
	return if last >= first then string.sub(row, first, last) else nil
end

greed.command({
	name = "goto-file",
	doc = "Open the file named under the cursor or in the selection",
	run = function(ctx)
		local selection = ctx.view:selection()
		local path = M.path_at(ctx.buffer, selection.ranges[selection.primary])
		if path == nil or path == "" then
			greed.echo("no file name under the cursor")
			return
		end
		-- Relative to the file it's named in, else to the project's root.
		local own = ctx.buffer:path()
		path = project.resolve(path, if own then string.match(own, "^(.*)/[^/]*$") else nil)
		if greed.fs.stat(path) == nil then
			greed.echo(`no file {path}`)
			return
		end
		greed.open(path)
	end,
})

M.keys = {
	["g n"] = "buffer-next",
	["g p"] = "buffer-prev",
	["g a"] = "goto-last-accessed-file",
	["g m"] = "goto-last-modified-file",
	["g ."] = "goto-last-modification",
	["g |"] = "goto-column",
	["g f"] = "goto-file",
	["g t"] = "goto-window-top",
	["g c"] = "goto-window-center",
	["g b"] = "goto-window-bottom",
} :: { [string]: string }

return M

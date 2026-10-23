-- Outlines: lines that belong together under one, like a Markdown list
-- item with the items under it, or a heading with its section, for the
-- languages a plugin knows them in (`provider`, as markdown does). Where
-- there's one, the line commands work on all of it: moving lines (alt-up
-- and alt-down in the vscode style) moves it past the one beside it at its
-- level, indenting and dedenting take the lines under it along, and
-- `zoom-in` shows only it, following it as it grows, until `zoom-out`.

local greed = require("@greed")
local registry = require("./registry")

type Buffer = greed.Buffer

local M = {}

--- Lines `first` to `last` (0-based, inclusive) that go together; `nests`
--- when indenting them puts them under the one before, as a list item.
export type Unit = { first: number, last: number, nests: boolean? }

--- Finds the innermost unit around 0-based `line`, and the units before and
--- after it at its level under the same one, when there are.
export type Provider = (buffer: Buffer, line: number) -> (Unit?, Unit?, Unit?)

--- Providers by language; set with `provider`.
M.providers = {} :: { [string]: Provider }

--- Finds units in `language` with `provider`, until the plugin that set it
--- goes.
function M.provider(language: string, provider: Provider)
	greed.plugin.cleanup(registry.set(M.providers, language, provider))
end

--- The unit around `line` in `buffer`, with the ones before and after it
--- at its level, if its language has outlines.
function M.at(buffer: Buffer, line: number): (Unit?, Unit?, Unit?)
	local language = buffer:language()
	local provider = language and M.providers[language]
	if provider == nil then
		return nil, nil, nil
	end
	return provider(buffer, line)
end

--- The lines the line commands work on for `lines` (0-based, in order) in
--- `buffer`: the first line of a unit that nests stands for all of it;
--- otherwise the lines as they are.
function M.lines(buffer: Buffer, lines: { number }): { number }
	if #lines ~= 1 then
		return lines
	end
	local unit = M.at(buffer, lines[1])
	if unit == nil or unit.first ~= lines[1] or not unit.nests then
		return lines
	end
	local out = {}
	for line = unit.first, unit.last do
		table.insert(out, line)
	end
	return out
end

--- A tab typed at the cursor in `view`, on a list item's first line with
--- one cursor: indents the item with what's under it when there's an item
--- before it to go under, and otherwise does nothing (there's nothing to
--- nest it in). Returns false elsewhere, for the tab to do what it does.
function M.tab(view: greed.View): boolean
	local selection = view:selection()
	if #selection.ranges ~= 1 then
		return false
	end
	local range = selection.ranges[1]
	local buffer = view:buffer()
	local line = buffer:line_of(range.head)
	if buffer:line_of(range.anchor) ~= line then
		return false
	end
	local unit, before = M.at(buffer, line)
	if unit == nil or not unit.nests or unit.first ~= line then
		return false
	end
	if before then
		greed.run("indent")
	end
	return true
end

--- Moves the unit around the cursor in `view` past the one after it at its
--- level (`down`) or the one before, the cursor going along. Returns false,
--- doing nothing, when the selection isn't in a single unit, so the lines
--- move as lines; true when it's in one, moved or not (nothing past it).
function M.move(view: greed.View, down: boolean): boolean
	local selection = view:selection()
	if #selection.ranges ~= 1 then
		return false
	end
	local buffer = view:buffer()
	local range = selection.ranges[1]
	local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
	local unit, before, after = M.at(buffer, buffer:line_of(from))
	if unit == nil or buffer:line_of(to) > unit.last then
		return false
	end
	local other = if down then after else before
	if other == nil then
		return true
	end
	local function text(u: Unit): string
		return buffer:slice(buffer:line_start(u.first), buffer:line_end(u.last))
	end
	local moved, passed = text(unit), text(other)
	local top, bottom = if down then unit else other, if down then other else unit
	local top_from, bottom_from = buffer:line_start(top.first), buffer:line_start(bottom.first)
	local top_to, bottom_to = buffer:line_end(top.last), buffer:line_end(bottom.last)
	-- Each takes the other's place, what's between them (blank lines)
	-- staying; the lower first, so the upper's place still holds.
	buffer:edit(function(e)
		e:replace(bottom_from, bottom_to, if down then moved else passed)
		e:replace(top_from, top_to, if down then passed else moved)
	end)
	local start = if down then top_from else bottom_from
	local by = if down then bottom_from + #passed - #moved - start else top_from - start
	view:set_selection({
		ranges = { { anchor = range.anchor + by, head = range.head + by } },
		primary = 1,
	})
	return true
end

-- The views zoomed in, by id: where the unit they show starts, followed
-- through edits.
local zoomed: { [number]: greed.Anchor } = {}

-- Shows only the unit starting at `anchor` in `view`, as it is now.
local function narrow(view: greed.View, anchor: greed.Anchor)
	local buffer = view:buffer()
	local pos = anchor:pos()
	local unit = if pos then M.at(buffer, buffer:line_of(pos)) else nil
	if unit then
		view:narrow(unit.first, unit.last)
	end
end

local function unzoom(id: number)
	local anchor = zoomed[id]
	if anchor then
		anchor:forget()
		zoomed[id] = nil
	end
end

-- Zooms `view` in to the unit starting on line `first`.
local function zoom(view: greed.View, first: number)
	unzoom(view:id())
	local buffer = view:buffer()
	local anchor = buffer:track(buffer:line_start(first))
	zoomed[view:id()] = anchor
	narrow(view, anchor)
end

--- Whether `view` is zoomed in to a unit.
function M.zoomed(view: greed.View): boolean
	return zoomed[view:id()] ~= nil
end

greed.command({
	name = "zoom-in",
	doc = "Show only the list item or section the cursor is in, with what's under it",
	run = function(ctx)
		local buffer = ctx.buffer
		local unit = M.at(buffer, buffer:line_of(ctx.view:cursor()))
		if unit == nil then
			greed.echo("nothing here to zoom in to")
			return
		end
		zoom(ctx.view, unit.first)
	end,
})

greed.command({
	name = "zoom-out",
	doc = "Show what's around the list item or section zoomed in to, or all of it again",
	run = function(ctx)
		local view = ctx.view
		local anchor = zoomed[view:id()]
		if anchor == nil then
			return
		end
		local buffer = ctx.buffer
		local pos = anchor:pos()
		unzoom(view:id())
		-- The unit it's in, if there is one; otherwise all of it.
		local first = if pos then buffer:line_of(pos) else 0
		for line = first - 1, 0, -1 do
			local unit = M.at(buffer, line)
			if unit and unit.first < first and unit.last >= first then
				zoom(view, unit.first)
				return
			end
		end
		view:narrow()
	end,
})

greed.keymap.bind({ layer = "leader" }, { z = "zoom-in", Z = "zoom-out" })

-- A zoomed view follows its unit as lines come and go in it.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	for id, anchor in zoomed do
		for _, view in event.buffer:views() do
			if view:id() == id then
				narrow(view, anchor)
			end
		end
	end
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	unzoom(event.view)
end)

return M

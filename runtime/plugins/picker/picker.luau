-- The picker itself: a floating buffer, kept in sync with what's typed.

local kern = require("@kern")
local menu = require("@core").menu

export type Item = {
	label: string,
	value: any,
}

--- What to show beside the picker for the current item.
export type Preview = {
	text: string,
	--- The language to highlight it as, e.g. from `kern.language_of(path)`.
	language: string?,
	--- A 0-based line to scroll to.
	line: number?,
}

export type Options = {
	--- Shows a preview of the current item beside the list. Returning nil
	--- leaves the preview empty.
	preview: ((item: Item) -> Preview?)?,
}

-- At most this many matches are shown.
local LIMIT = 200

type Open = {
	buffer: kern.Buffer,
	view: kern.View,
	items: { Item },
	labels: { string },
	query: string?,
	matches: { number },
	current: number,
	choose: (item: Item) -> (),
	-- The mode to go back to when the picker closes.
	mode: string,
	preview: ((item: Item) -> Preview?)?,
	preview_view: kern.View?,
	-- The item the preview shows.
	previewed: Item?,
}

-- Shows the current item in the preview, if it changed.
local function update_preview(o: Open)
	local view, preview = o.preview_view, o.preview
	if view == nil or preview == nil then
		return
	end
	local index = o.matches[o.current]
	local item = if index then o.items[index] else nil
	if item == o.previewed then
		return
	end
	o.previewed = item
	local shown = if item then preview(item) else nil
	local text = if shown then shown.text else ""
	view:show(kern.create_buffer("preview", text, { readonly = true, language = shown and shown.language }))
	view:configure({ title = if shown then (item :: Item).label else "" })
	if shown and shown.line then
		local buffer = view:buffer()
		local line = math.clamp(shown.line, 0, buffer:line_count() - 1)
		local at = buffer:line_start(line)
		view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	end
end

local open: Open? = nil

local function query(o: Open): string
	return o.buffer:slice(0, o.buffer:line_end(0))
end

-- Rewrites the lines below the query to show the matches, keeping the
-- cursor where it is in the query.
local function render(o: Open)
	local lines = {}
	local marks: { kern.Mark } = {}
	local from = o.buffer:line_end(0) + 1
	for i, index in o.matches do
		if i > LIMIT then
			break
		end
		local line = " " .. o.labels[index]
		menu.mark_row(marks, from, line, i == o.current, kern.fuzzy_positions(o.query or "", o.labels[index]), 1)
		table.insert(lines, line)
		from += #line + 1
	end
	local selection = o.view:selection()
	o.buffer:edit(function(e)
		e:replace(o.buffer:line_end(0), o.buffer:len(), "\n" .. table.concat(lines, "\n"))
		e:select(selection)
	end)
	o.buffer:decorate("picker", marks)
	update_preview(o)
end

-- Filters the items again if the query changed.
local function refresh(o: Open)
	local q = query(o)
	if q == o.query then
		return
	end
	o.query = q
	o.matches = kern.fuzzy(q, o.labels)
	o.current = 1
	render(o)
end

kern.on("buffer.changed", function(event: kern.BufferChanged)
	if open and event.buffer:id() == open.buffer:id() then
		refresh(open)
	end
end)

local function close()
	if open then
		local view, mode, preview = open.view, open.mode, open.preview_view
		open = nil
		view:close()
		if preview then
			preview:close()
		end
		kern.mode.set(mode)
	end
end

local function move(delta: number)
	if open and #open.matches > 0 then
		local count = math.min(#open.matches, LIMIT)
		open.current = (open.current - 1 + delta) % count + 1
		render(open)
	end
end

kern.command({
	name = "picker-next",
	doc = "Move to the next item in the picker",
	run = function()
		move(1)
	end,
})

kern.command({
	name = "picker-prev",
	doc = "Move to the previous item in the picker",
	run = function()
		move(-1)
	end,
})

kern.command({
	name = "picker-choose",
	doc = "Choose the current item and close the picker",
	run = function()
		local o = open
		if o == nil then
			return
		end
		local index = o.matches[o.current]
		close()
		if index then
			o.choose(o.items[index])
		end
	end,
})

kern.command({
	name = "picker-close",
	doc = "Close the picker without choosing",
	run = close,
})

local M = {}

-- Opens a picker over `items`. `choose` gets the item picked with enter;
-- `options.preview` shows the current item beside the list.
function M.pick(title: string, items: { Item }, choose: (item: Item) -> (), options: Options?)
	close()
	local labels = {}
	for i, item in items do
		labels[i] = item.label
	end
	local preview = options and options.preview
	-- With a preview, the list takes the left half and the preview the right.
	local preview_view = if preview
		then kern.float(
			kern.create_buffer("preview", "", { readonly = true }),
			{ x = "50%", width = "46%", height = "70%", focus = false }
		)
		else nil
	local buffer = kern.create_buffer("picker")
	local view = if preview
		then kern.float(buffer, { title = title, x = "4%", width = "46%", height = "70%" })
		else kern.float(buffer, { title = title, width = "60%", height = "60%" })
	local o: Open = {
		buffer = buffer,
		view = view,
		items = items,
		labels = labels,
		matches = {},
		current = 1,
		choose = choose,
		preview = preview,
		preview_view = preview_view,
		mode = kern.mode.get(),
	}
	open = o
	kern.mode.set("insert")
	refresh(o)
end

return M

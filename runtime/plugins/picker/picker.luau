-- The picker itself: a floating buffer, kept in sync with what's typed.

local kern = require("@kern")
local menu = require("@core").menu

export type Item = {
	label: string,
	value: any,
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
}

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
		local view, mode = open.view, open.mode
		open = nil
		view:close()
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

-- Opens a picker over `items`. `choose` gets the item picked with enter.
function M.pick(title: string, items: { Item }, choose: (item: Item) -> ())
	close()
	local labels = {}
	for i, item in items do
		labels[i] = item.label
	end
	local buffer = kern.create_buffer("picker")
	local view = kern.float(buffer, { title = title, width = "60%", height = "60%" })
	local o: Open = {
		buffer = buffer,
		view = view,
		items = items,
		labels = labels,
		matches = {},
		current = 1,
		choose = choose,
		mode = kern.mode.get(),
	}
	open = o
	kern.mode.set("insert")
	refresh(o)
end

return M

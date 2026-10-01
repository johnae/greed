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
	--- More keys for this picker, e.g. `["ctrl-e"] = ...`. Each closes the
	--- picker and gets the items matching what was typed, best first.
	keys: { [string]: (items: { Item }) -> () }?,
	--- Asks for the items as the query changes, instead of filtering a fixed
	--- list, for searches too big to list up front. It runs `delay` ms after
	--- typing stops and can wait, e.g. on `kern.fs.grep`; answers for a query
	--- that has since changed are dropped. `items` can be empty then.
	source: ((query: string) -> { Item })?,
	--- Milliseconds without typing before `source` runs; 100 by default.
	delay: number?,
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
	keys: { [string]: (items: { Item }) -> () },
	source: ((query: string) -> { Item })?,
	delay: number,
	-- Goes up with each query, so a source's late answer can tell it's stale.
	generation: number,
	searching: boolean,
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
	view:show(
		kern.create_buffer(
			"preview",
			text,
			{ readonly = true, language = shown and shown.language }
		)
	)
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
		menu.mark_row(
			marks,
			from,
			line,
			i == o.current,
			if o.source then {} else kern.fuzzy_positions(o.query or "", o.labels[index]),
			1
		)
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

-- Puts `items` in the list, as a source's answer.
local function set_items(o: Open, items: { Item })
	o.items = items
	o.labels = {}
	o.matches = {}
	for i, item in items do
		o.labels[i] = item.label
		o.matches[i] = i
	end
	o.current = 1
	render(o)
end

-- Asks the source for items until the answer is for the latest query.
-- Typing while it works makes it go again; answers in between are dropped.
local function search(o: Open, source: (query: string) -> { Item })
	o.searching = true
	while open == o do
		local generation = o.generation
		local ok, items = pcall(source, o.query or "")
		if open ~= o then
			break
		end
		if generation == o.generation then
			set_items(o, if ok then items else {})
			break
		end
	end
	o.searching = false
end

-- Filters the items again if the query changed, or with a source, asks it
-- once typing pauses.
local function refresh(o: Open)
	local q = query(o)
	if q == o.query then
		return
	end
	o.query = q
	local source = o.source
	if source == nil then
		o.matches = kern.fuzzy(q, o.labels)
		o.current = 1
		render(o)
		return
	end
	o.generation += 1
	local generation = o.generation
	if q == "" then
		set_items(o, {})
		return
	end
	kern.sleep(o.delay)
	if open == o and generation == o.generation and not o.searching then
		search(o, source)
	end
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

-- The keys every picker has.
local KEYS: { [string]: string } = {
	down = "picker-next",
	up = "picker-prev",
	["ctrl-n"] = "picker-next",
	["ctrl-p"] = "picker-prev",
	enter = "picker-choose",
	esc = "picker-close",
}

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

kern.command({
	name = "picker-key",
	doc = "Run what the open picker does for the key pressed",
	run = function(ctx)
		local o = open
		local key = ctx.keys or ""
		local action = o and o.keys[key]
		if o == nil or action == nil then
			-- Another picker bound this key; in this one it does what it
			-- usually does.
			local usual = KEYS[key]
			if usual then
				kern.run(usual)
			end
			return
		end
		local items = {}
		for _, index in o.matches do
			table.insert(items, o.items[index])
		end
		close()
		action(items)
	end,
})

-- The keys bound to picker-key so far, for any picker.
local bound: { [string]: boolean } = {}

local M = {}

M.KEYS = KEYS

-- Opens a picker over `items`. `choose` gets the item picked with enter;
-- `options.preview` shows the current item beside the list, and
-- `options.source` makes the items follow the query.
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
		keys = options and options.keys or {},
		source = options and options.source,
		delay = options and options.delay or 100,
		generation = 0,
		searching = false,
		mode = kern.mode.get(),
	}
	for key in o.keys do
		if not bound[key] then
			bound[key] = true
			kern.keymap.bind({ mode = "insert", kind = "picker" }, { [key] = "picker-key" })
		end
	end
	open = o
	kern.mode.set("insert")
	refresh(o)
end

return M

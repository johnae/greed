-- Floating views move and resize with the mouse: drag the top border (where
-- the title is) to move one, an edge or a corner to resize it. Pressing on
-- a float's border brings it to the front.
--
-- Also here, the two kinds of float plugins open most: one you type in,
-- like a prompt or a picker (`typing`), and one showing some text to read
-- (`show_text`).

local greed = require("@greed")
local style = require("./style")
local registry = require("./registry")

local M = {}

--- The smallest a float gets by dragging, border included.
M.min_width = 10
M.min_height = 3

type Area = { x: number, y: number, width: number, height: number }

-- The float being dragged: which part was pressed, where, and the box it
-- had then, border included.
local dragging: { view: greed.View, part: string, col: number, row: number, box: Area }? = nil

--- Where `box` would go after dragging its `part` by `dx` and `dy`
--- cells: the top border moves it, the other edges and the corners resize it.
function M.dragged(box: Area, part: string, dx: number, dy: number): Area
	local x, y, width, height = box.x, box.y, box.width, box.height
	if part == "top" then
		return { x = math.max(0, x + dx), y = math.max(0, y + dy), width = width, height = height }
	end
	if string.find(part, "left", 1, true) then
		dx = math.min(dx, width - M.min_width)
		x += dx
		width -= dx
	elseif string.find(part, "right", 1, true) then
		width += dx
	end
	if string.find(part, "top", 1, true) then
		dy = math.min(dy, height - M.min_height)
		y += dy
		height -= dy
	elseif string.find(part, "bottom", 1, true) then
		height += dy
	end
	return {
		x = math.max(0, x),
		y = math.max(0, y),
		width = math.max(M.min_width, width),
		height = math.max(M.min_height, height),
	}
end

--- Whether `view` is floating.
function M.is_float(view: greed.View): boolean
	return view:float_spec() ~= nil
end

-- `view`'s box as last drawn, border included; nil before it's drawn.
local function box_of(view: greed.View): Area?
	local area = view:area()
	if area == nil then
		return nil
	end
	return { x = area.x - 1, y = area.y - 1, width = area.width + 2, height = area.height + 2 }
end

local function place(view: greed.View, box: Area)
	view:configure({ x = box.x, y = box.y, width = box.width, height = box.height })
end

--- Grows the float `view` by `cells` toward `side` ("left", "right", "up"
--- or "down"), or shrinks it from that side with negative `cells`.
function M.grow(view: greed.View, side: string, cells: number)
	local box = box_of(view)
	if box == nil then
		return
	end
	-- The top border moves a float, so growing up takes the top-left corner
	-- with no change across.
	local part = if side == "up" then "top-left" elseif side == "down" then "bottom" else side
	local dx = if side == "left" then -cells elseif side == "right" then cells else 0
	local dy = if side == "up" then -cells elseif side == "down" then cells else 0
	place(view, M.dragged(box, part, dx, dy))
end

--- Moves the float `view` by `dx` columns and `dy` rows.
function M.move(view: greed.View, dx: number, dy: number)
	local box = box_of(view)
	if box then
		place(view, M.dragged(box, "top", dx, dy))
	end
end

greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind == "press" and event.button == "left" and event.border and event.view then
		local view = event.view
		local box = box_of(view)
		if box == nil then
			return
		end
		local part: string = event.border
		view:raise()
		view:focus()
		dragging = { view = view, part = part, col = event.col, row = event.row, box = box }
	elseif event.kind == "drag" and dragging then
		local drag = dragging
		local box = M.dragged(drag.box, drag.part, event.col - drag.col, event.row - drag.row)
		-- The float may have closed under the mouse.
		if not pcall(place, drag.view, box) then
			dragging = nil
		end
	elseif event.kind == "release" then
		dragging = nil
	end
end)

--- A float being typed in, from `typing`.
export type Typing = {
	view: greed.View,
	buffer: greed.Buffer,
	--- Closes it, if it's still open.
	close: () -> (),
	--- Whether it's still open.
	is_open: () -> boolean,
}

export type TypingOptions = {
	--- The mode to type in while it's open; "insert" by default.
	mode: string?,
	--- Called after each change to the buffer.
	on_change: (() -> ())?,
	--- Called once it's closed, however that happened: by `close`, or by
	--- closing its view some other way. The mode is back by then.
	on_close: (() -> ())?,
}

--- Opens `buffer` in a float (see `greed.float` for `spec`) to type in,
--- like a prompt or a picker, and switches to `options.mode`. However it
--- closes, the mode goes back: to the one it was opened from if focus goes
--- back there, otherwise to the one for the view focused then. A float
--- with `focus = false`, like a completion menu over the text being typed,
--- goes back only if the mode is still its own.
function M.typing(buffer: greed.Buffer, spec: greed.FloatSpec, options: TypingOptions?): Typing
	local opts: TypingOptions = options or {}
	local mode = opts.mode or "insert"
	local came_from, was = greed.view(), greed.mode.get()
	local view = greed.float(buffer, spec)
	local id = view:id()
	local open = true

	local function restore()
		if spec.focus == false then
			if greed.mode.get() == mode then
				greed.mode.set(was)
			end
		elseif greed.view() == came_from then
			greed.mode.set(was)
		else
			greed.mode.set(style.home_for(greed.view()))
		end
	end

	-- Its view may have closed with the news yet to come.
	local function changed(event: greed.BufferChanged)
		if open and event.buffer == buffer and view:valid() and opts.on_change then
			opts.on_change()
		end
	end
	local closed: (event: greed.ViewClosed) -> ()
	local function finish()
		if not open then
			return
		end
		open = false
		greed.off("buffer.changed", changed)
		greed.off("view.closed", closed)
		restore()
		if opts.on_close then
			opts.on_close()
		end
	end
	function closed(event: greed.ViewClosed)
		if event.view == id then
			finish()
		end
	end
	greed.on("buffer.changed", changed)
	greed.on("view.closed", closed)
	greed.mode.set(mode)

	return {
		view = view,
		buffer = buffer,
		close = function()
			if open then
				-- It may have closed with the news yet to come.
				if view:valid() then
					view:close()
				end
				finish()
			end
		end,
		is_open = function()
			return open
		end,
	}
end

export type TextOptions = {
	--- The buffer's kind, for keys of its own; "text" by default. Showing
	--- text with a kind closes the float showing text of that kind before.
	kind: string?,
	--- The language to highlight the text as.
	language: string?,
	--- Marks to put on the text, e.g. styles for parts of it.
	marks: { greed.Mark }?,
	--- "80%" and "60%" of the screen by default.
	width: (number | string)?,
	height: (number | string)?,
}

-- The float last showing text of each kind.
local showing: { [string]: greed.View } = {}

greed.command({
	name = "text-float-close",
	doc = "Close the float showing text",
	run = function(ctx)
		if showing[ctx.buffer:kind()] == ctx.view then
			ctx.view:close()
		end
	end,
})

--- Shows `text` in a float titled `title`, to read: it can't be changed,
--- and esc or q closes it.
---
---     core.floats.show_text("Stalls", table.concat(lines, "\n"), { kind = "stalls" })
function M.show_text(title: string, text: string, options: TextOptions?): greed.View
	local opts: TextOptions = options or {}
	local kind = opts.kind or "text"
	local before = showing[kind]
	if before == nil then
		greed.keymap.bind(
			{ mode = "normal", kind = kind },
			{ esc = "text-float-close", q = "text-float-close" }
		)
	elseif before:valid() then
		before:close()
	end
	local buffer = greed.create_buffer(kind, text, { readonly = true, language = opts.language })
	if opts.marks then
		buffer:decorate("text-float", opts.marks)
	end
	local view = greed.float(
		buffer,
		{ title = title, width = opts.width or "80%", height = opts.height or "60%" }
	)
	showing[kind] = view
	return view
end

-- The buffers that need you, by buffer id, and who to tell when that
-- changes.
local attention: { [number]: boolean } = {}
local watchers: { () -> () } = {}

--- Says whether `buffer` needs you: an agent waiting for an answer, a
--- command that finished out of sight. Float layouts give its float a
--- colored dot. Its owner sets it and takes it off again.
function M.attention(buffer: greed.Buffer, needed: boolean)
	local id = buffer:id()
	if (attention[id] ~= nil) == needed then
		return
	end
	if needed then
		attention[id] = true
	else
		attention[id] = nil
	end
	for _, watch in watchers do
		watch()
	end
end

--- Whether `buffer` needs you, as `attention` last said.
function M.needs_attention(buffer: greed.Buffer): boolean
	return attention[buffer:id()] ~= nil
end

--- Calls `watch` whenever a buffer starts or stops needing you, until the
--- plugin that asked goes.
function M.on_attention(watch: () -> ())
	greed.plugin.tie(registry.put(watchers, watch))
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	attention[event.id] = nil
end)

return M

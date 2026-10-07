-- Image files open as the image: PNG, JPEG and GIF, drawn as wide as the
-- view at most (in the window, and in terminals that show images), under a
-- line with its name, size and zoom.
--
--   +  -  bigger, smaller
--   =     as wide as the view, or its own size when it's smaller
--   0     its own size

local greed = require("@greed")
local core = require("@core")

type Viewer = {
	buffer: greed.Buffer,
	path: string,
	image: number,
	-- How much bigger than its own size it's drawn; nil to fit the view.
	zoom: number?,
}

local viewers: { [number]: Viewer } = {}

local EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true }

local function set_text(buffer: greed.Buffer, text: string)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), text)
	end)
end

-- The columns a view showing `v` has, or a terminal's usual width.
local function cols_of(v: Viewer): number
	local view = v.buffer:views()[1]
	local cols = if view then select(2, view:size()) else nil
	return cols or 80
end

-- The scale that fits an image `natural_cols` wide in `cols` columns,
-- never bigger than its own size.
local function fit(natural_cols: number, cols: number): number
	return math.min(1, cols / math.max(natural_cols, 1))
end

-- Draws the image at its zoom, or fit to `cols` columns.
local function show(v: Viewer, cols: number)
	local width, height = greed.image.size(v.image)
	local natural_cols, natural_rows = greed.image.cells(v.image)
	if not (width and height and natural_cols and natural_rows) then
		set_text(v.buffer, `{v.path}: can't show it`)
		return
	end
	local scale = v.zoom or fit(natural_cols, cols)
	local image_cols = math.max(1, math.round(natural_cols * scale))
	local rows = math.max(1, math.round(natural_rows * scale))
	local name = core.project.basename(v.path) or v.path
	local zoom = math.round(scale * 100)
	set_text(v.buffer, `{name}  {width}×{height}  {zoom}%\n` .. string.rep("\n", rows - 1))
	v.buffer:decorate("image", {
		{ from = 0, to = v.buffer:line_end(0), style = "image.title" },
		{
			from = v.buffer:line_start(1),
			to = v.buffer:line_start(v.buffer:line_count() - 1),
			style = "image.image",
			image = { id = v.image, cols = image_cols, rows = rows },
		},
	})
end

local M = {}

--- Shows the image at `path` in each of `views` (the focused view by
--- default). Returns the viewer's buffer, or nil and why.
function M.open(path: string, views: { greed.View }?): (greed.Buffer?, string?)
	local image, err = greed.image.load(path)
	if image == nil then
		return nil, err
	end
	local buffer = greed.create_buffer("image", "", { readonly = true })
	buffer:set_line_numbers(false)
	buffer:forget_history()
	local v: Viewer = { buffer = buffer, path = path, image = image }
	viewers[buffer:id()] = v
	local shown_in: { greed.View } = views or { greed.view() }
	for _, view in shown_in do
		view:show(buffer)
	end
	show(v, cols_of(v))
	return buffer, nil
end

local function viewer(ctx: greed.Context): Viewer?
	return viewers[ctx.buffer:id()]
end

-- Zooms the image in the view by `by`, from what it's drawn at now.
local function zoom(ctx: greed.Context, by: number)
	local v = viewer(ctx)
	if v == nil then
		return
	end
	local natural_cols = greed.image.cells(v.image) or 1
	local now = v.zoom or fit(natural_cols, cols_of(v))
	v.zoom = math.clamp(now * by, 0.05, 16)
	show(v, cols_of(v))
end

greed.command({
	name = "image-zoom-in",
	doc = "Draw the image bigger",
	run = function(ctx)
		zoom(ctx, 1.25)
	end,
})

greed.command({
	name = "image-zoom-out",
	doc = "Draw the image smaller",
	run = function(ctx)
		zoom(ctx, 0.8)
	end,
})

greed.command({
	name = "image-zoom-fit",
	doc = "Draw the image as wide as the view, or at its own size when it's smaller",
	run = function(ctx)
		local v = viewer(ctx)
		if v then
			v.zoom = nil
			show(v, cols_of(v))
		end
	end,
})

greed.command({
	name = "image-zoom-actual",
	doc = "Draw the image at its own size",
	run = function(ctx)
		local v = viewer(ctx)
		if v then
			v.zoom = 1
			show(v, cols_of(v))
		end
	end,
})

-- Bound for the kind of buffer, these work in every style and mode; the
-- buffer is read-only, so typing has nothing to lose to them.
greed.keymap.bind({ kind = "image" }, {
	["+"] = "image-zoom-in",
	["-"] = "image-zoom-out",
	["="] = "image-zoom-fit",
	["0"] = "image-zoom-actual",
})

core.file.opener(function(path)
	return EXTENSIONS[string.lower(string.match(path, "%.(%w+)$") or "")] ~= nil
end, function(path, views)
	local _, err = M.open(path, views)
	return err
end)

greed.on("view.resized", function(event: greed.ViewResized)
	local v = viewers[event.view:buffer():id()]
	if v and v.zoom == nil then
		show(v, event.cols)
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	local v = viewers[event.id]
	if v then
		viewers[event.id] = nil
		greed.image.forget(v.image)
	end
end)

return M

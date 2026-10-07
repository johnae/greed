-- PDF files open as their pages: one page at a time, drawn as wide as the
-- view (in terminals that show images, and in the window), or as the text
-- on every page, which reads anywhere and searches with `/`.
--
--   ]  [     next and previous page
--   +  -  =  bigger, smaller, as wide as the view
--   t        pages or text

local greed = require("@greed")
local core = require("@core")

type Viewer = {
	doc: greed.PdfDocument,
	buffer: greed.Buffer,
	page: number,
	-- The page's width as a share of the view's.
	zoom: number,
	text: boolean,
	-- The image of the page shown, and the line each page's text starts on.
	image: number?,
	starts: { number },
}

local viewers: { [number]: Viewer } = {}

local function set_text(buffer: greed.Buffer, text: string)
	buffer:edit(function(e)
		e:replace(0, #buffer:text(), text)
	end)
end

-- The page drawn to fit the view's width at its zoom, under a line saying
-- which page it is.
local function show_page(v: Viewer, cols: number)
	local cell_w = greed.image.cell_size()
	local width = v.doc:size(v.page)
	local image, err = v.doc:render(v.page, cols * v.zoom * cell_w / (width :: number))
	if image == nil then
		set_text(v.buffer, `page {v.page} of {v.doc.pages}: {err}`)
		v.buffer:decorate("pdf", {})
		return
	end
	if v.image then
		greed.image.forget(v.image)
	end
	v.image = image
	local image_cols, rows = greed.image.cells(image)
	set_text(v.buffer, `page {v.page} of {v.doc.pages}\n` .. string.rep("\n", (rows :: number) - 1))
	v.buffer:decorate("pdf", {
		{ from = 0, to = 0, style = "pdf.page" },
		{
			from = v.buffer:line_start(1),
			to = v.buffer:line_start(v.buffer:line_count() - 1),
			style = "pdf.image",
			image = { id = image, cols = image_cols :: number, rows = rows :: number },
		},
	})
end

-- Every page's text, each under a line saying which page it is.
local function show_text(v: Viewer)
	local parts = {}
	local line = 0
	for page = 1, v.doc.pages do
		local text = v.doc:text(page) or ""
		local part = `── page {page} ──\n{text}`
		v.starts[page] = line
		table.insert(parts, part)
		local _, breaks = string.gsub(part, "\n", "")
		line += breaks
	end
	set_text(v.buffer, table.concat(parts))
	local marks = {}
	for _, start in v.starts do
		table.insert(
			marks,
			{ from = v.buffer:line_start(start), to = v.buffer:line_end(start), style = "pdf.page" }
		)
	end
	v.buffer:decorate("pdf", marks)
end

-- The columns a view showing `v` has, or a terminal's usual width.
local function cols_of(v: Viewer): number
	local view = v.buffer:views()[1]
	local cols = if view then select(2, view:size()) else nil
	return cols or 80
end

local function show(v: Viewer)
	if v.text then
		if #v.starts == 0 then
			show_text(v)
		end
		local start = v.starts[v.page]
		local at = v.buffer:line_start(start)
		for _, view in v.buffer:views() do
			view:set_cursor(at)
			view:set_scroll(start)
		end
	else
		show_page(v, cols_of(v))
		for _, view in v.buffer:views() do
			view:set_cursor(0)
			view:set_scroll(0)
		end
	end
end

local M = {}

--- Shows the PDF at `path` in each of `views` (the focused view by
--- default). Returns the viewer's buffer, or nil and why not.
function M.open(path: string, views: { greed.View }?): (greed.Buffer?, string?)
	local doc, err = greed.pdf.open(path)
	if doc == nil then
		return nil, err
	end
	local buffer = greed.create_buffer("pdf", "", { readonly = true })
	buffer:set_line_numbers(false)
	local v: Viewer = { doc = doc, buffer = buffer, page = 1, zoom = 1, text = false, starts = {} }
	viewers[buffer:id()] = v
	local shown_in: { greed.View } = views or { greed.view() }
	for _, view in shown_in do
		view:show(buffer)
	end
	show(v)
	return buffer, nil
end

local function viewer(ctx: greed.Context): Viewer?
	return viewers[ctx.buffer:id()]
end

local function command(name: string, doc: string, run: (v: Viewer, ctx: greed.Context) -> ())
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local v = viewer(ctx)
			if v then
				run(v, ctx)
			end
		end,
	})
end

-- In the text, the page is the one the cursor is on.
local function page_at_cursor(v: Viewer, ctx: greed.Context)
	if not v.text then
		return
	end
	local line = v.buffer:line_of(ctx.view:cursor())
	for page, start in v.starts do
		if start <= line then
			v.page = page
		end
	end
end

local function go(v: Viewer, ctx: greed.Context, delta: number)
	page_at_cursor(v, ctx)
	local page = math.clamp(v.page + delta * (ctx.count or 1), 1, v.doc.pages)
	if page ~= v.page then
		v.page = page
		show(v)
	end
end

command("pdf-next-page", "Show the next page of the PDF", function(v, ctx)
	go(v, ctx, 1)
end)
command("pdf-previous-page", "Show the previous page of the PDF", function(v, ctx)
	go(v, ctx, -1)
end)

local function zoom(v: Viewer, to: number)
	to = math.clamp(to, 0.2, 1)
	if to ~= v.zoom then
		v.zoom = to
		if not v.text then
			show(v)
		end
	end
end

command("pdf-zoom-in", "Draw the PDF's page bigger", function(v)
	zoom(v, v.zoom + 0.1)
end)
command("pdf-zoom-out", "Draw the PDF's page smaller", function(v)
	zoom(v, v.zoom - 0.1)
end)
command("pdf-zoom-fit", "Draw the PDF's page as wide as the view", function(v)
	zoom(v, 1)
end)
command("pdf-text", "Switch between the PDF's pages and the text on them", function(v, ctx)
	page_at_cursor(v, ctx)
	v.text = not v.text
	show(v)
end)

-- Bound for normal mode, these work in every style; the buffer is read-only,
-- so even modeless editing can have them.
greed.keymap.bind({ mode = "normal", kind = "pdf" }, {
	["]"] = "pdf-next-page",
	["["] = "pdf-previous-page",
	["+"] = "pdf-zoom-in",
	["-"] = "pdf-zoom-out",
	["="] = "pdf-zoom-fit",
	t = "pdf-text",
})

core.file.opener(function(path)
	return string.match(string.lower(path), "%.pdf$") ~= nil
end, function(path, views)
	local _, err = M.open(path, views)
	return err
end)

greed.on("view.resized", function(event: greed.ViewResized)
	local v = viewers[event.view:buffer():id()]
	if v and not v.text then
		show_page(v, event.cols)
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	local v = viewers[event.id]
	if v then
		viewers[event.id] = nil
		if v.image then
			greed.image.forget(v.image)
		end
	end
end)

return M

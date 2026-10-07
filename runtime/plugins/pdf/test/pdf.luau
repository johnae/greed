local test = require("@greed/test")
local greed = require("@greed")

-- A PDF with a page of text for each of `pages`, objects and then the
-- table of where each starts.
local function sample(pages: { string }): string
	local objects = {}
	local kids = {}
	for i = 1, #pages do
		table.insert(kids, `{2 + i * 2} 0 R`)
	end
	table.insert(objects, "<< /Type /Catalog /Pages 2 0 R >>")
	table.insert(objects, `<< /Type /Pages /Kids [{table.concat(kids, " ")}] /Count {#pages} >>`)
	table.insert(objects, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
	for i, text in pages do
		local content = `BT /F1 24 Tf 72 720 Td ({text}) Tj ET`
		table.insert(
			objects,
			`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {3 + i * 2} 0 R >>`
		)
		table.insert(objects, `<< /Length {#content} >>\nstream\n{content}\nendstream`)
	end
	local out = { "%PDF-1.4\n" }
	local size = #out[1]
	local offsets = {}
	for i, object in objects do
		table.insert(offsets, size)
		local part = `{i} 0 obj\n{object}\nendobj\n`
		table.insert(out, part)
		size += #part
	end
	table.insert(out, `xref\n0 {#objects + 1}\n0000000000 65535 f \n`)
	for _, offset in offsets do
		table.insert(out, string.format("%010d 00000 n \n", offset))
	end
	table.insert(out, `trailer\n<< /Size {#objects + 1} /Root 1 0 R >>\nstartxref\n{size}\n%%EOF\n`)
	return table.concat(out)
end

local function open(t: test.TestContext): greed.Buffer
	local dir = t:tempdir({ ["a.pdf"] = sample({ "First page", "Second page", "Third page" }) })
	greed.open(dir .. "/a.pdf")
	t:wait_for(function()
		return greed.view():buffer():kind() == "pdf"
	end)
	return greed.view():buffer()
end

local function image(buffer: greed.Buffer): { id: number, cols: number, rows: number }?
	for _, mark in buffer:decorations("pdf") do
		if mark.image then
			return mark.image
		end
	end
	return nil
end

test("a PDF opens as its first page, drawn as wide as the view", function(t)
	t:buffer("|")
	local buffer = open(t)
	assert(string.find(buffer:text(), "page 1 of 3", 1, true), buffer:text())
	local shown = assert(image(buffer), "the page is an image")
	assert(shown.cols == 80, `as wide as the view: {shown.cols}`)
	local cell_w, cell_h = greed.image.cell_size()
	local width, height = greed.image.size(shown.id)
	assert(width == 80 * cell_w, `{width} pixels for 80 cells`)
	assert(shown.rows == math.ceil((height :: number) / cell_h), `{shown.rows} rows`)
	assert(buffer:line_count() == shown.rows + 1, "a line for each row, under the page's")
	assert(buffer:readonly())
end)

test("] and [ go through the pages, - and = zoom", function(t)
	t:buffer("|")
	local buffer = open(t)
	local first = assert(image(buffer)).id
	t:keys("]")
	assert(string.find(buffer:text(), "page 2 of 3", 1, true), buffer:text())
	assert(greed.image.size(first) == nil, "the last page's image is forgotten")
	t:keys("] ] ]")
	assert(string.find(buffer:text(), "page 3 of 3", 1, true), "no page after the last")
	t:keys("2 [")
	assert(string.find(buffer:text(), "page 1 of 3", 1, true), "counts go that many pages")
	t:keys("- -")
	assert(assert(image(buffer)).cols == 64, `smaller: {assert(image(buffer)).cols}`)
	t:keys("=")
	assert(assert(image(buffer)).cols == 80)
end)

test("t shows the text of every page, from the one shown, and back", function(t)
	t:buffer("|")
	local buffer = open(t)
	t:keys("]")
	t:keys("t")
	local text = buffer:text()
	assert(
		string.find(
			text,
			"── page 1 ──\nFirst page\n── page 2 ──\nSecond page\n",
			1,
			true
		),
		text
	)
	assert(image(buffer) == nil)
	local head = greed.view():selection().ranges[1].head
	assert(buffer:line_of(head) == 2, "on page 2's heading")
	t:keys("]")
	assert(buffer:line_of(greed.view():selection().ranges[1].head) == 4, "] goes to the next page")
	t:keys("t")
	assert(string.find(buffer:text(), "page 3 of 3", 1, true), "the page the cursor was on")
end)

test("a file that isn't a PDF says so and stays as it is", function(t)
	t:buffer("|")
	local dir = t:tempdir({ ["b.pdf"] = "not a pdf" })
	greed.open(dir .. "/b.pdf")
	t:wait(10)
	assert(greed.view():buffer():kind() == "file")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "can't read the PDF", 1, true), said)
end)

test("the keys work in a style no plugin names", function(t)
	t:buffer("|")
	local buffer = open(t)
	require("@core").style.define({ name = "mine", doc = "Mine", mode = "mine" })
	require("@core").style.set("mine")
	t:expect_mode("mine")
	t:keys("]")
	assert(string.find(buffer:text(), "page 2 of 3", 1, true), buffer:text())
end)

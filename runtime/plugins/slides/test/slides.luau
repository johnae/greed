local test = require("@greed/test")
local greed = require("@greed")
local slides = require("@slides")

local DECK = table.concat({
	"---",
	"title: Orders",
	"---",
	"",
	"# Orders",
	"",
	"What changed this quarter.",
	"",
	"---",
	"",
	"## Numbers",
	"",
	"```sh",
	"echo 42",
	"```",
	"",
	"```speaker",
	"Mention the outage.",
	"```",
	"",
	"---",
	"",
	"A heading under a line",
	"---",
	"",
	"```text",
	"---",
	"```",
	"",
}, "\n")

test("slides go from one --- line to the next, notes and front matter left out", function(t)
	t:buffer(DECK .. "|")
	greed.view():buffer():set_language("markdown")
	local found = slides.slides(greed.view():buffer())
	assert(#found == 3, `{#found} slides`)
	-- Lines are 0-based: "# Orders" is line 4.
	assert(found[1].first == 4 and found[1].last == 6, `{found[1].first}-{found[1].last}`)
	assert(found[2].first == 10 and found[2].last == 14, `{found[2].first}-{found[2].last}`)
	assert(found[2].notes == "Mention the outage.", tostring(found[2].notes))
	-- A setext heading's underline and a --- in code don't start a slide.
	assert(found[3].first == 22 and found[3].last == 27, `{found[3].first}-{found[3].last}`)
	assert(found[1].notes == nil, "no notes on the first")
end)

-- The view showing the slides, and the lines it's narrowed to.
local function shown(): (greed.View, number?, number?)
	local view = greed.view()
	local from, to = view:narrowed()
	return view, from, to
end

test(":slides shows the slide the cursor is on, and the keys go from slide to slide", function(t)
	t:buffer("|" .. DECK)
	greed.view():buffer():set_language("markdown")
	local deck = greed.view()
	-- On "## Numbers".
	deck:set_cursor(greed.view():buffer():line_start(10))
	t:run("slides")
	local view, from, to = shown()
	assert(view ~= deck, "a view of its own")
	assert(not greed.client.current().status_line, "no status line while presenting")
	assert(from == 10 and to == 14, `{from}-{to}`)
	local spec = view:float_spec()
	assert(spec and spec.label == "2/3", tostring(spec and spec.label))
	t:keys("right")
	view, from, to = shown()
	assert(from == 22, `next: {from}`)
	t:keys("right")
	view, from = shown()
	assert(from == 22, "the last stays")
	t:keys("home")
	view, from = shown()
	assert(from == 4, `first: {from}`)
	t:keys("left")
	view, from = shown()
	assert(from == 4, "the first stays")
	-- The deck's own view keeps its keys.
	t:keys("q")
	assert(greed.view() == deck, "back in the deck")
	assert(not view:valid(), "the slides are gone")
	assert(greed.client.current().status_line, "the status line is back")
	local before = greed.view():buffer():text()
	t:keys("i q esc")
	assert(greed.view():buffer():text() ~= before, "q types in the deck's own view")
end)

test("running a block on a slide shows its result there", function(t)
	t:buffer("|" .. DECK)
	greed.view():buffer():set_language("markdown")
	greed.view():set_cursor(greed.view():buffer():line_start(10))
	t:run("slides")
	t:keys("r")
	-- A buffer without a file may run its blocks without asking.
	t:wait_for(function()
		return string.find(greed.view():buffer():text(), "```result\n42\n```", 1, true) ~= nil
	end)
	local _, from, to = shown()
	-- The result's four lines (blank, fence, 42, fence) are on the slide.
	assert(from == 10 and to == 18, `{from}-{to}`)
end)

test(":slides says so outside Markdown", function(t)
	t:buffer("|")
	greed.view():buffer():set_language("rust")
	t:run("slides")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "Markdown", 1, true), said)
end)

test("a deck's front matter centers its slides, across and down", function(t)
	t:buffer("|---\nslides-center: true\nslides-margin: 0\n---\n\n# Hi\n\nsome text\n")
	greed.view():buffer():set_language("markdown")
	t:run("slides")
	local rows = t:screen(40, 12)
	local at = nil
	for i, row in rows do
		if string.find(row, "some text", 1, true) then
			at = i
		end
	end
	assert(at and at > 4, `down the middle: {table.concat(rows, "\n")}`)
	local before = string.find(rows[at], "some text", 1, true) or 0
	assert(before > 12, `across the middle: {rows[at]}`)
end)

test("slides-scale: fit draws a slide as big as fits", function(t)
	t:buffer(
		"|---\nslides-scale: fit\nslides-margin: 0\n---\n\nshort\n\n---\n\n"
			.. string.rep("a long line ", 8)
			.. "\n"
	)
	greed.view():buffer():set_language("markdown")
	-- The client's screen, which the slides fit.
	t:screen(60, 20)
	t:run("slides")
	local function scale(): number
		local most = 1
		for _, mark in greed.view():buffer():decorations("slides.scale") do
			most = math.max(most, mark.scale or 1)
		end
		return most
	end
	assert(scale() == 4, `a word fits four times as big: {scale()}`)
	t:keys("right")
	assert(scale() == 1, `a long line fits as it is: {scale()}`)
end)

-- An 8 by 64 PNG.
local PNG =
	"\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82\0\0\0\8\0\0\0\64\8\0\0\0\0\2\111\105\86\0\0\0\18\73\68\65\84\120\156\99\104\128\2\134\81\198\40\131\116\6\0\19\32\0\16\91\154\159\85\0\0\0\0\73\69\78\68\174\66\96\130"

test("a picture on a line of its own shows on the slide, as big as fits", function(t)
	local dir = t:tempdir({
		["deck.md"] = "# Look\n\n![A tall one](tall.png)\n\nUnder it.\n",
		["tall.png"] = PNG,
	})
	greed.open(`{dir}/deck.md`)
	t:screen(60, 12)
	t:run("slides")
	local marks = greed.view():buffer():decorations("slides.pictures")
	assert(#marks == 1, `one picture: {#marks}`)
	local shown = assert(marks[1].image)
	-- It's taller than the slide's room beside the heading and the text,
	-- so it's made smaller; never bigger than it is.
	local cols, rows = greed.image.cells(shown.id)
	assert(cols and rows and shown.rows < rows and shown.rows <= 12, `{shown.rows} of {rows}`)
	assert(marks[1].text == "A tall one", "its description where images can't show")
end)

test("a terminal that can't draw text bigger gets slides at their usual size", function(t)
	t:buffer("|---\nslides-scale: fit\n---\n\nshort\n")
	greed.view():buffer():set_language("markdown")
	local term = t:client("term", "tui")
	term:screen(60, 20)
	term:run("slides")
	for _, mark in greed.view():buffer():decorations("slides.scale") do
		assert((mark.scale or 1) == 1, `scaled {mark.scale} where it can't be drawn so`)
	end
end)

-- The screen `client` (or the test's own) shows, as one string.
local function seen(c: any, rows: number?): string
	return table.concat(c:screen(80, rows or 30), "\n")
end

test("another screen joins the slides and follows them, and leaves on its own", function(t)
	t:buffer("|" .. DECK)
	greed.view():buffer():set_language("markdown")
	t:screen(80, 30)
	t:run("slides")
	local second = t:client("second")
	second:screen(80, 30)
	second:run("slides")
	assert(string.find(seen(second), "What changed this quarter.", 1, true), seen(second))
	-- Moving on one screen moves the other.
	t:keys("right")
	assert(string.find(seen(second), "Numbers", 1, true), seen(second))
	second:keys("right")
	assert(string.find(seen(t), "A heading under a line", 1, true), seen(t))
	-- q leaves one screen; the other goes on.
	second:keys("q")
	assert(not string.find(seen(second), "1/3", 1, true), "the second left")
	t:keys("home")
	assert(string.find(seen(t), "What changed this quarter.", 1, true), seen(t))
end)

test("the presenter sees the notes, the next slide and the time beside the slide", function(t)
	t:buffer("|" .. DECK)
	greed.view():buffer():set_language("markdown")
	greed.view():set_cursor(greed.view():buffer():line_start(10))
	t:screen(120, 30)
	t:run("slides-presenter")
	local shown = seen(t)
	assert(string.find(shown, "Slide 2 of 3 · 0:00", 1, true), shown)
	assert(string.find(shown, "Mention the outage.", 1, true), "its notes")
	assert(string.find(shown, "A heading under a line", 1, true), "the start of the next")
	assert(string.find(shown, "echo 42", 1, true), "the slide itself")
	-- The keys work from either side, and the notes follow.
	t:keys("right")
	assert(string.find(seen(t), "No notes for this slide.", 1, true), seen(t))
	assert(string.find(seen(t), "The end.", 1, true), "nothing comes next")
	t:keys("q")
	assert(#t:floats() == 0, "both sides closed")
end)

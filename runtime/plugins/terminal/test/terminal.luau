local test = require("@kern/test")
local kern = require("@kern")

local function text(): string
	return kern.view():buffer():text()
end

local function shows(t: test.TestContext, wanted: string)
	t:wait_for(function()
		return string.find(text(), wanted, 1, true) ~= nil
	end)
end

test(":terminal runs a program and shows what it prints", function(t)
	t:run("terminal", { "sh", "-c", "printf 'hello\\nthere'; exit 3" })
	local buffer = kern.view():buffer()
	assert(buffer:kind() == "terminal")
	shows(t, "hello\nthere")
	t:wait_for(function()
		return #buffer:decorations("terminal.exit") > 0
	end)
	local exit = buffer:decorations("terminal.exit")[1]
	assert(exit.lines and exit.lines[1] == "[exited with 3]", exit.lines and exit.lines[1])
	assert(kern.mode.get() == "normal", kern.mode.get())
end)

test("keys go to the program until ctrl-\\, and i goes back", function(t)
	t:run("terminal", { "cat" })
	assert(kern.mode.get() == "terminal")
	t:keys("h i enter")
	shows(t, "hi\nhi")
	t:keys("ctrl-\\")
	assert(kern.mode.get() == "normal")
	t:keys("i")
	assert(kern.mode.get() == "terminal")
	-- Keys bound for every mode, like ctrl-q to quit, go to the program too.
	t:keys("ctrl-q o k enter")
	shows(t, "ok\nok")
	assert(not t:quitting())
	t:keys("ctrl-d")
end)

test("the program's colors are shown", function(t)
	t:run("terminal", { "sh", "-c", "printf 'plain \\033[31mred\\033[0m'; exit 1" })
	local buffer = kern.view():buffer()
	shows(t, "plain red")
	local marks = buffer:decorations("terminal.screen")
	assert(#marks == 1, tostring(#marks))
	assert(buffer:slice(marks[1].from, marks[1].to) == "red")
	assert(marks[1].style == "=fg:red", marks[1].style)
end)

test("lines that scroll off stay above the screen, as many as the option says", function(t)
	kern.option.set("terminal-scrollback", 20)
	t:draw(40, 11)
	t:run("terminal", { "sh", "-c", "seq 1 100; exit 1" })
	local buffer = kern.view():buffer()
	shows(t, "\n100\n")
	t:wait_for(function()
		return #buffer:decorations("terminal.exit") > 0
	end)
	-- 20 lines above a screen of 10.
	assert(buffer:line_count() == 30, tostring(buffer:line_count()))
	local first = buffer:slice(0, buffer:line_end(0))
	assert(first == "72", first)
end)

test("a program that ends well closes its terminal", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	kern.open(dir .. "/a.txt")
	t:run("terminal", { "true" })
	t:wait_for(function()
		return kern.view():buffer():kind() ~= "terminal"
	end)
	assert(text() == "before")
	assert(kern.mode.get() == "normal")
end)

test("the program hears when the view changes size", function(t)
	t:draw(60, 20)
	t:run("terminal", { "sh", "-c", "read x; stty size; exit 1" })
	t:draw(50, 12)
	t:keys("enter")
	shows(t, "11 50")
end)

test("p pastes the latest copy into the program", function(t)
	t:run("terminal", { "cat" })
	t:keys("ctrl-\\")
	kern.clipboard.set("pasted")
	t:keys("p")
	t:keys("i enter")
	shows(t, "pasted\npasted")
	t:keys("ctrl-d")
end)

test(":terminal-close ends the program and goes back", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	kern.open(dir .. "/a.txt")
	t:run("terminal", { "cat" })
	t:keys("ctrl-\\")
	t:run("terminal-close")
	assert(text() == "before")
end)

test("space t switches back to a terminal, or opens a new one", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	kern.open(dir .. "/a.txt")
	t:run("terminal", { "cat" })
	t:keys("ctrl-\\")
	kern.open(dir .. "/a.txt")
	t:keys("space t")
	local floats = t:floats()
	assert(string.find(table.concat(floats, "\n"), "cat", 1, true), table.concat(floats, "\n"))
	t:keys("c a t enter")
	assert(kern.view():buffer():kind() == "terminal")
	assert(kern.mode.get() == "terminal")
	t:keys("ctrl-d")
end)

test("images a program shows become image marks over their cells", function(t)
	local pixels = "/wAAAAD/"
	t:run("terminal", {
		"sh",
		"-c",
		`printf '\\033_Ga=T,f=24,s=2,v=1,c=4,r=2,q=2;{pixels}\\033\\\\after'; exit 1`,
	})
	local buffer = kern.view():buffer()
	shows(t, "after")
	local images: { kern.Mark } = {}
	for _, mark in buffer:decorations("terminal.screen") do
		if mark.image then
			table.insert(images, mark)
		end
	end
	assert(#images == 1, `one mark for the image, not one a row: {#images}`)
	local image = assert(images[1].image)
	assert(image.cols == 4 and image.rows == 2 and image.row == 0, `{image.cols}x{image.rows}`)
	local width, height = kern.image.size(image.id)
	assert(width == 2 and height == 1, `{width}x{height}`)
	-- The mark reaches the image's last row, so it's drawn while any of it
	-- shows.
	assert(buffer:line_of(images[1].to) == buffer:line_of(images[1].from) + 1)
end)

test("ctrl-space reaches the space keys from inside a terminal", function(t)
	t:run("terminal", { "cat" })
	assert(kern.mode.get() == "terminal")
	t:keys("ctrl-space")
	assert(kern.mode.get() == "normal")
	local _, more = kern.keymap.resolve("space")
	assert(more, "space is pending")
	t:keys("esc i ctrl-d")
end)

test("the wheel scrolls back through the output, and down again types into it", function(t)
	kern.option.set("terminal-scrollback", 100)
	t:draw(40, 11)
	t:run("terminal", { "sh", "-c", "seq 1 60; cat" })
	local buffer = kern.view():buffer()
	shows(t, "\n60\n")
	t:draw(40, 11)
	local bottom = kern.view():scroll()
	t:mouse("scroll", 3, 3, "up")
	assert(kern.mode.get() == "normal", "scrolling up stops typing into it")
	assert(kern.view():scroll() < bottom, tostring(kern.view():scroll()))
	t:mouse("scroll", 3, 3, "down")
	assert(kern.mode.get() == "terminal", "back at the bottom it types again")
	assert(buffer:kind() == "terminal")
	t:keys("ctrl-d")
end)

test("a program that asks for the mouse gets it", function(t)
	t:draw(40, 10)
	t:run(
		"terminal",
		{ "sh", "-c", "printf '\\033[?1000h\\033[?1006hready'; stty raw -echo; cat -v" }
	)
	shows(t, "ready")
	t:draw(40, 10)
	t:mouse("press", 4, 2)
	shows(t, "^[[<0;5;3M")
end)

test("what a program copies goes on the clipboard", function(t)
	-- "copied" in base64, as OSC 52 carries it.
	t:run("terminal", { "sh", "-c", "printf '\\033]52;c;Y29waWVk\\007done'; exit 1" })
	shows(t, "done")
	local copy = kern.clipboard.get()
	assert(copy and copy[1] == "copied", copy and copy[1])
end)

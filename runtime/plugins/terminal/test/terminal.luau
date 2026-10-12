local test = require("@greed/test")
local greed = require("@greed")

local function text(): string
	return greed.view():buffer():text()
end

-- Takes `name` out of `map`, which doesn't allow nil values.
local function forget<V>(map: { [string]: V }, name: string)
	map[name] = nil
end

local function shows(t: test.TestContext, wanted: string)
	t:wait_for(function()
		return string.find(text(), wanted, 1, true) ~= nil
	end)
end

test(":terminal runs a program and shows what it prints", function(t)
	t:run("terminal", { "sh", "-c", "printf 'hello\\nthere'; exit 3" })
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "terminal")
	shows(t, "hello\nthere")
	assert(#buffer:history() == 0, "its output isn't kept to undo")
	t:wait_for(function()
		return #buffer:decorations("terminal.exit") > 0
	end)
	local exit = buffer:decorations("terminal.exit")[1]
	assert(
		exit.lines and exit.lines[1] == "[exited with 3]",
		tostring(exit.lines and exit.lines[1])
	)
	assert(greed.mode.get() == "helix", greed.mode.get())
end)

test("keys go to the program until ctrl-\\, and i goes back", function(t)
	t:run("terminal", { "cat" })
	assert(greed.mode.get() == "terminal")
	t:keys("h i enter")
	shows(t, "hi\nhi")
	t:keys("ctrl-\\")
	assert(greed.mode.get() == "helix")
	t:keys("i")
	assert(greed.mode.get() == "terminal")
	-- Keys bound for every mode, like ctrl-q to quit, go to the program too.
	t:keys("ctrl-q o k enter")
	shows(t, "ok\nok")
	assert(not t:quitting())
	t:keys("ctrl-d")
end)

test("the program's colors are shown", function(t)
	t:run("terminal", { "sh", "-c", "printf 'plain \\033[31mred\\033[0m'; exit 1" })
	local buffer = greed.view():buffer()
	shows(t, "plain red")
	local marks = buffer:decorations("terminal.screen")
	assert(#marks == 1, tostring(#marks))
	assert(buffer:slice(marks[1].from, marks[1].to) == "red")
	assert(marks[1].style == "=fg:red", marks[1].style)
end)

test("lines that scroll off stay above the screen, as many as the option says", function(t)
	greed.option.set("terminal-scrollback", 20)
	t:draw(40, 11)
	t:run("terminal", { "sh", "-c", "seq 1 100; exit 1" })
	local buffer = greed.view():buffer()
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
	greed.open(dir .. "/a.txt")
	t:run("terminal", { "true" })
	t:wait_for(function()
		return greed.view():buffer():kind() ~= "terminal"
	end)
	assert(text() == "before")
	assert(greed.mode.get() == "helix")
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
	greed.clipboard.set("pasted")
	t:keys("p")
	t:keys("i enter")
	shows(t, "pasted\npasted")
	t:keys("ctrl-d")
end)

test(":terminal-close ends the program and goes back", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	greed.open(dir .. "/a.txt")
	t:run("terminal", { "cat" })
	t:keys("ctrl-\\")
	t:run("terminal-close")
	assert(text() == "before")
end)

test("space t switches back to a terminal, or opens a new one", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	greed.open(dir .. "/a.txt")
	t:run("terminal", { "cat" })
	t:keys("ctrl-\\")
	greed.open(dir .. "/a.txt")
	t:keys("space t")
	local floats = t:floats()
	assert(string.find(table.concat(floats, "\n"), "cat", 1, true), table.concat(floats, "\n"))
	t:keys("c a t enter")
	assert(greed.view():buffer():kind() == "terminal")
	assert(greed.mode.get() == "terminal")
	t:keys("ctrl-d")
end)

test("images a program shows become image marks over their cells", function(t)
	local pixels = "/wAAAAD/"
	t:run("terminal", {
		"sh",
		"-c",
		`printf '\\033_Ga=T,f=24,s=2,v=1,c=4,r=2,q=2;{pixels}\\033\\\\after'; exit 1`,
	})
	local buffer = greed.view():buffer()
	shows(t, "after")
	local images: { greed.Mark } = {}
	for _, mark in buffer:decorations("terminal.screen") do
		if mark.image then
			table.insert(images, mark)
		end
	end
	assert(#images == 1, `one mark for the image, not one a row: {#images}`)
	local image = assert(images[1].image)
	assert(image.cols == 4 and image.rows == 2 and image.row == 0, `{image.cols}x{image.rows}`)
	local width, height = greed.image.size(image.id)
	assert(width == 2 and height == 1, `{width}x{height}`)
	-- The mark reaches the image's last row, so it's drawn while any of it
	-- shows.
	assert(buffer:line_of(images[1].to) == buffer:line_of(images[1].from) + 1)
end)

test("ctrl-space reaches the space keys from inside a terminal", function(t)
	t:run("terminal", { "cat" })
	assert(greed.mode.get() == "terminal")
	t:keys("ctrl-space")
	assert(greed.mode.get() == "helix")
	local _, more = greed.keymap.resolve("space")
	assert(more, "space is pending")
	t:keys("esc i ctrl-d")
end)

test("the wheel scrolls back through the output, and down again types into it", function(t)
	greed.option.set("terminal-scrollback", 100)
	t:draw(40, 11)
	t:run("terminal", { "sh", "-c", "seq 1 60; cat" })
	local buffer = greed.view():buffer()
	shows(t, "\n60\n")
	t:draw(40, 11)
	local bottom = greed.view():scroll()
	t:mouse("scroll", 3, 3, "up")
	assert(greed.mode.get() == "helix", "scrolling up stops typing into it")
	assert(greed.view():scroll() < bottom, tostring(greed.view():scroll()))
	t:mouse("scroll", 3, 3, "down")
	assert(greed.mode.get() == "terminal", "back at the bottom it types again")
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
	local copy = greed.clipboard.get()
	assert(copy and copy[1] == "copied", copy and copy[1])
end)

-- Points the link-opener option at a script that writes what it opens to
-- a file, and returns the file.
local function record_opens(t: test.TestContext): string
	local dir = t:tempdir({ ["open.sh"] = 'printf %s "$1" > "$(dirname "$0")/opened"\n' })
	greed.option.set("link-opener", `sh {dir}/open.sh`)
	return `{dir}/opened`
end

local function opened(t: test.TestContext, file: string): string?
	local found: string?
	t:wait_for(function()
		found = greed.fs.read(file)
		return found ~= nil
	end)
	return found
end

test("links a program prints are underlined and g x opens them", function(t)
	local file = record_opens(t)
	t:run("terminal", {
		"sh",
		"-c",
		"printf 'see \\033]8;;https://example.com/a\\033\\\\the site\\033]8;;\\033\\\\'; exit 1",
	})
	shows(t, "see the site")
	local buffer = greed.view():buffer()
	local link
	for _, mark in buffer:decorations("terminal.screen") do
		if mark.style == "markup.link" then
			link = mark
		end
	end
	assert(link and buffer:slice(link.from, link.to) == "the site")
	t:wait_for(function()
		return greed.mode.get() == "helix"
	end)
	greed.view():set_selection({ ranges = { { anchor = 6, head = 6 } }, primary = 1 })
	t:keys("g x")
	assert(opened(t, file) == "https://example.com/a")
end)

test("g x opens a URL written in the output", function(t)
	local file = record_opens(t)
	t:run("terminal", { "sh", "-c", "echo 'go to https://example.com/b.'; exit 1" })
	shows(t, "go to")
	t:wait_for(function()
		return greed.mode.get() == "helix"
	end)
	greed.view():set_selection({ ranges = { { anchor = 12, head = 12 } }, primary = 1 })
	t:keys("g x")
	assert(opened(t, file) == "https://example.com/b")
end)

test("links keep working after they scroll off the screen", function(t)
	local file = record_opens(t)
	t:draw(40, 8)
	t:run("terminal", {
		"sh",
		"-c",
		"printf '\\033]8;;https://example.com/c\\033\\\\up here\\033]8;;\\033\\\\\\n'; seq 1 30; exit 1",
	})
	shows(t, "\n30")
	t:wait_for(function()
		return greed.mode.get() == "helix"
	end)
	greed.view():set_selection({ ranges = { { anchor = 2, head = 2 } }, primary = 1 })
	t:keys("g x")
	assert(opened(t, file) == "https://example.com/c")
end)

test("terminals get the environment plugins add", function(t)
	local terminal = require("@terminal")
	terminal.env.GREED_TEST_GREETING = "hello from a plugin"
	t:run("terminal", { "sh", "-c", "echo $GREED_TEST_GREETING; exit 1" })
	forget(terminal.env, "GREED_TEST_GREETING")
	shows(t, "hello from a plugin")
end)

test("a program that can't start leaves the view as it was", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	greed.open(dir .. "/a.txt")
	local ok = pcall(t.run, t, "terminal", { "greed-test-no-such-program" })
	assert(not ok, "it fails")
	assert(text() == "before")
	for _, buffer in greed.buffers() do
		assert(buffer:kind() ~= "terminal", "no terminal left behind")
	end
end)

test("closing a terminal's buffer with :bc ends its program", function(t)
	t:run("terminal", { "cat" })
	local buffer = greed.view():buffer()
	local terminal = require("@terminal")
	assert(terminal.terminal(buffer), "a terminal")
	t:keys("ctrl-\\")
	t:run("buffer-close")
	assert(terminal.terminal(buffer) == nil, "its terminal is gone")
	assert(greed.view():buffer():kind() == "file", greed.view():buffer():kind())
end)

test("esc goes to the program, and esc twice quickly stops typing into it", function(t)
	t:run("terminal", { "cat", "-v" })
	t:keys("esc enter")
	shows(t, "^[")
	assert(greed.mode.get() == "terminal", "one esc stays")
	t:keys("esc")
	t:wait(400)
	t:keys("esc")
	assert(greed.mode.get() == "terminal", "two escs far apart stay")
	t:keys("esc esc")
	assert(greed.mode.get() == "helix", "two quickly leave")
	t:keys("i ctrl-d")
end)

test("on the normal screen, esc esc leaves without the program getting an esc", function(t)
	t:run("terminal", { "cat", "-v" })
	t:keys("esc esc")
	assert(greed.mode.get() == "helix", "left")
	t:keys("i x enter")
	shows(t, "x")
	assert(not string.find(greed.view():buffer():text(), "^[", 1, true), "no esc reached it")
	-- One esc on its own reaches it once the wait is up.
	t:keys("esc")
	t:wait(400)
	t:keys("enter")
	shows(t, "^[")
	t:keys("ctrl-d")
end)

test(
	"a full screen program gets esc at once, and so does any with terminal-esc-wait off",
	function(t)
		t:run("terminal", { "sh", "-c", "printf '\\033[?1049h'; cat -v" })
		local terminal = assert(require("@terminal").terminal(greed.view():buffer()))
		t:wait_for(function()
			return terminal:modes().alternate
		end)
		t:keys("esc esc")
		assert(greed.mode.get() == "helix", "left")
		t:keys("i enter")
		shows(t, "^[")
		t:keys("ctrl-d")
		greed.option.set("terminal-esc-wait", false)
		t:run("terminal", { "cat", "-v" })
		t:keys("esc esc")
		t:keys("i enter")
		shows(t, "^[")
		t:keys("ctrl-d")
		greed.option.set("terminal-esc-wait", true)
	end
)

-- A shell session the way a shell that marks its prompts prints it: a
-- command with output that fails with 2, then another prompt.
local MARKED = table.concat({
	"printf '\\033]133;A\\007$ \\033]133;B\\007ls\\n\\033]133;C\\007one\\ntwo\\n\\033]133;D;2\\007",
	"\\033]133;A\\007$ \\033]133;B\\007pwd\\n\\033]133;C\\007/tmp\\n\\033]133;D;0\\007",
	"\\033]133;A\\007$ \\033]133;B\\007'; sleep 5",
})

test("a shell's marked commands: go between them, select their output, see what failed", function(t)
	t:run("terminal", { "sh", "-c", MARKED })
	shows(t, "/tmp\n$ ")
	t:keys("ctrl-\\")
	local buffer = greed.view():buffer()
	local commands = require("@terminal").commands(buffer)
	assert(#commands == 3, tostring(#commands))
	assert(commands[1].code == 2 and commands[2].code == 0)
	t:keys("g g ] p")
	t:expect((buffer:text():gsub("pwd", "|pwd", 1)))
	t:keys("[ p")
	t:expect((buffer:text():gsub("ls", "|ls", 1)))
	t:keys("g o")
	local selection = greed.view():selection().ranges[1]
	assert(buffer:slice(selection.anchor, selection.head) == "one\ntwo", "the output")
	local exits = buffer:decorations("terminal.exits")
	assert(#exits == 1 and exits[1].text == "exit 2", "only the failure shows")
end)

test("without marks, going between commands says why", function(t)
	t:run("terminal", { "sh", "-c", "echo plain; sleep 5" })
	shows(t, "plain")
	t:keys("ctrl-\\ ] p")
	local messages = t:messages()
	assert(string.find(messages[#messages], "no commands marked", 1, true), messages[#messages])
end)

test(
	"the folder the shell says it's in is where new terminals start and paths come from",
	function(t)
		local dir = t:tempdir({ ["src/main.rs"] = "fn main() {\n    let x = 1;\n}\n" })
		t:run(
			"terminal",
			{ "sh", "-c", `printf '\\033]7;file://box{dir}\\007src/main.rs:2:9: oops'; sleep 5` }
		)
		shows(t, "oops")
		local buffer = greed.view():buffer()
		local terminal = require("@terminal")
		assert(terminal.cwd(buffer) == dir, terminal.cwd(buffer))
		-- Said rather than shown: a long folder, like macOS's temporary ones,
		-- wraps in the terminal.
		t:run("terminal", {
			"sh",
			"-c",
			`[ "$(pwd -P)" = "$(cd '{dir}' && pwd -P)" ] && echo started-there; sleep 5`,
		})
		t:keys("esc esc")
		shows(t, "started-there")
		t:run("terminal-close")
		t:keys("ctrl-\\ g g g x")
		assert(greed.view():buffer():path() == dir .. "/src/main.rs", greed.view():buffer():path())
		t:expect("fn main() {\n    let |x = 1;\n}\n")
	end
)

test("files and lines the output names: go between them, pick one to open", function(t)
	local dir =
		t:tempdir({ ["src/main.rs"] = "fn main() {\n    let x: u8 = 300;\n}\n", ["notes.md"] = "" })
	local output = table.concat({
		"error[E0308]: mismatched types",
		" --> src/main.rs:2:17",
		"warning: gone.rs:1:1 is not there",
		"see notes.md for more",
	}, "\\n")
	t:run("terminal", { "sh", "-c", `printf '\\033]7;file://box{dir}\\007{output}'; sleep 5` })
	shows(t, "for more")
	local buffer = greed.view():buffer()
	local refs = require("@terminal").references(buffer)
	assert(#refs == 1, "only files that are there, with a line: " .. tostring(#refs))
	assert(refs[1].line == 2 and refs[1].col == 17, tostring(refs[1].line))
	assert(refs[1].text == "error[E0308]: mismatched types --> src/main.rs:2:17", refs[1].text)
	t:keys("ctrl-\\ g g ] e")
	local selection = greed.view():selection().ranges[1]
	assert(buffer:slice(selection.anchor, selection.head + 1) == "src/main.rs:2:17")
	t:keys("space d")
	local floats = table.concat(t:floats(), "\n")
	assert(string.find(floats, "src/main.rs:2  error[E0308]", 1, true), floats)
	t:keys("enter")
	assert(greed.view():buffer():path() == dir .. "/src/main.rs")
	t:expect("fn main() {\n    let x: u8 = |300;\n}\n")
end)

test("space T sends the line, or the selection, to the terminal used last and runs it", function(t)
	local dir = t:tempdir({ ["a.sh"] = "echo first\necho second\n" })
	-- Without the terminal's echo, which can land in the middle of what cat
	-- prints, the buffer holds only cat's output, in order.
	t:run("terminal", { "sh", "-c", "stty -echo; echo ready; cat" })
	shows(t, "ready")
	local terminal = greed.view():buffer()
	t:keys("ctrl-\\")
	greed.open(dir .. "/a.sh")
	t:keys("space T")
	t:wait_for(function()
		return string.find(terminal:text(), "ready\necho first\n", 1, true) ~= nil
	end)
	t:keys("x x space T")
	t:wait_for(function()
		return string.find(terminal:text(), "ready\necho first\necho first\necho second\n", 1, true)
			~= nil
	end)
	local messages = t:messages()
	assert(string.find(messages[#messages], "sent to sh", 1, true), messages[#messages])
end)

test("space T without a terminal says how to get one", function(t)
	t:buffer("|hello")
	t:keys("space T")
	local messages = t:messages()
	assert(string.find(messages[#messages], "no terminal to send to", 1, true), messages[#messages])
end)

test("a program in a terminal, or a command its shell runs, keeps the session", function(t)
	local file = require("@core").file
	t:run("terminal", { "cat" })
	local busy = file.busy()
	assert(#busy == 1 and string.find(busy[1], "cat", 1, true), busy[1])
	t:keys("ctrl-d")
	t:wait_for(function()
		return #file.busy() == 0
	end)

	t:run("terminal", { "sh" })
	t:wait_for(function()
		return string.find(text(), "$", 1, true) ~= nil
	end)
	assert(#file.busy() == 1, "sh was asked for by name, so it counts as a program")
	t:keys("e x i t enter")
end)

test("a terminal is sized for the client typing into it, not the others", function(t)
	t:draw(60, 20)
	t:run("terminal", { "cat" })
	local buffer = greed.view():buffer()
	local terminal = require("@terminal").terminal(buffer) :: greed.Terminal
	local function rows(): number
		return #terminal:screen().rows
	end
	local function sized(want_rows: number, want_cols: number): boolean
		local size = buffer:screen_size()
		return size ~= nil and size.rows == want_rows and size.cols == want_cols
	end
	assert(rows() == 19, `{rows()} rows`)
	local second = t:client("laptop")
	second:draw(40, 10)
	assert(rows() == 19, "the second's smaller view doesn't resize it")
	-- Typing into it sizes it for the second's screen.
	second:keys("x")
	assert(rows() == 9 and sized(9, 40), `{rows()} rows for the second`)
	-- The first sees it at that size, with a note on whose it is.
	local screen = table.concat(t:screen(60, 20), "\n")
	assert(string.find(screen, "40×9 for laptop", 1, true), screen)
	-- The first's window changing size doesn't fight over it.
	t:draw(70, 22)
	second:draw(40, 10)
	assert(rows() == 9 and sized(9, 40), "still the second's")
	-- Until the first types into it again.
	t:keys("y")
	assert(rows() == 21 and sized(21, 70), `{rows()} rows for the first`)
	t:keys("ctrl-d")
end)

test("a terminal another plugin started shows in a view and gives it back after", function(t)
	local dir = t:tempdir({ ["a.txt"] = "before" })
	greed.open(dir .. "/a.txt")
	local before = greed.view():buffer()
	local script = "printf '\\033[?1049h'; sleep 0.2; printf '\\033[?1049l'; echo done"
	local started = greed.terminal.spawn({ command = { "sh", "-c", script }, rows = 10, cols = 40 })
	local terminal = require("@terminal")
	local term = terminal.adopt(started, { return_on_primary = true, title = "full screen" })
	local shown = greed.view():buffer()
	assert(shown:kind() == "terminal" and terminal.terminal(shown) == started, shown:kind())
	assert(greed.mode.get() == "terminal", greed.mode.get())
	-- Leaving the alternate screen, or exiting, gives the view back.
	t:wait_for(function()
		return greed.view():buffer() == before
	end)
	assert(not terminal.is_open(term))
	assert(greed.mode.get() == "helix", greed.mode.get())
	-- The program goes on, and the terminal stays its starter's to read.
	t:wait_for(function()
		return started:exit_code() ~= nil
	end)
	local said = {}
	for _, row in started:screen().rows do
		table.insert(said, row.text)
	end
	assert(string.find(table.concat(said, "\n"), "done", 1, true), table.concat(said, "\n"))
	started:close()
end)

test(
	"an adopted terminal is sized for the view, and closing it ends its program but not the terminal",
	function(t)
		local dir = t:tempdir({ ["a.txt"] = "before" })
		greed.open(dir .. "/a.txt")
		t:draw(50, 12)
		local rows, cols = greed.view():size()
		local started = greed.terminal.spawn({
			command = { "sh", "-c", "read x; stty size; sleep 30" },
			rows = 5,
			cols = 20,
		})
		local terminal = require("@terminal")
		terminal.adopt(started, { title = "sleeper" })
		t:keys("enter")
		shows(t, `{rows} {cols}`)
		t:keys("ctrl-\\")
		t:run("terminal-close")
		assert(text() == "before", text())
		assert(started:valid(), "the starter still has it")
		t:wait_for(function()
			return started:exit_code() ~= nil
		end)
		started:close()
	end
)

test("references in part of a buffer resolve against a given folder", function(t)
	local dir = t:tempdir({ ["refs-here/main.rs"] = "fn main() {}\n", ["refs-here/lib.rs"] = "\n" })
	local lines = {
		"refs-here/main.rs:1:4 first",
		"refs-here/lib.rs:1 second",
		"refs-here/main.rs:1:1 third",
	}
	local buffer = greed.create_buffer("file", table.concat(lines, "\n"))
	local terminal = require("@terminal")
	assert(#terminal.references(buffer) == 0, "not from the project's root")
	local all = terminal.references(buffer, { cwd = dir })
	assert(#all == 3, tostring(#all))
	assert(all[1].path == dir .. "/refs-here/main.rs" and all[1].line == 1 and all[1].col == 4)
	local some = terminal.references(buffer, {
		from = buffer:line_start(1),
		to = buffer:line_end(1),
		cwd = dir,
	})
	assert(#some == 1, tostring(#some))
	assert(some[1].path == dir .. "/refs-here/lib.rs" and some[1].line == 1, some[1].path)
	assert(some[1].text == "refs-here/lib.rs:1 second", some[1].text)
end)

test("a client typing into a terminal isn't left typing into what another client shows", function(t)
	t:buffer("|hello")
	t:run("terminal", { "cat" })
	local term = greed.view():buffer()
	local second = t:client()
	second:expect_mode("terminal")
	-- The first opens a tab: the second is moved there, out of the terminal's mode.
	t:keys("ctrl-\\")
	greed.command({
		name = "test-new-tab",
		run = function()
			greed.tab.new()
		end,
	})
	t:run("test-new-tab")
	second:expect_mode("helix")
	second:keys("j k")
	assert(not string.find(term:text(), "jk", 1, true), term:text())
	assert(not greed.view():buffer():modified(), "nothing typed into the new tab's buffer")
	-- Closing the terminal another client types into does the same.
	greed.command({
		name = "test-first-tab",
		run = function()
			greed.tab.switch(greed.tab.list()[1].id)
		end,
	})
	second:run("test-first-tab")
	second:keys("i")
	second:expect_mode("terminal")
	t:run("test-first-tab")
	t:run("terminal-close")
	second:expect_mode("helix")
end)

test("a terminal is an object: what runs, where, and whether it still does", function(t)
	local core = require("@core")
	local dir = t:tempdir()
	t:run("terminal", { "sh", "-c", `cd '{dir}'; echo ready; sleep 5` })
	shows(t, "ready")
	local buffer = greed.view():buffer()
	local term = assert(core.objects.get(`terminal:{buffer:id()}`))
	local listed = false
	for _, object in core.objects.list("terminal") do
		listed = listed or object.id == term.id
	end
	assert(listed, "listed")
	local state = core.objects.inspect(term)
	assert(state.running == true and state.program == "sh", greed.json.encode(state))
	local related = core.objects.related(term)
	assert(related.buffer[1].id == `buffer:{buffer:id()}`)
	assert(related.views[1].id == `view:{greed.view():id()}`)
end)

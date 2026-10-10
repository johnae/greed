local test = require("@greed/test")
local greed = require("@greed")

local function describe_command(t: test.TestContext, command: string)
	t:buffer("|")
	t:keys("space h c")
	t:keys((string.gsub(command, ".", "%0 ")))
	t:keys("enter")
end

test("describing a command shows its doc, keys and source", function(t)
	describe_command(t, "next-word")
	local help = t:floats()[1]
	assert(help, "a help window opens")
	assert(string.find(help, "Select to the start of the next word", 1, true), help)
	assert(string.find(help, "Keys: w (helix)", 1, true), help)
	assert(string.find(help, "Defined in core/motions.luau:", 1, true), help)
end)

test("enter jumps to the definition", function(t)
	describe_command(t, "next-word")
	t:keys("enter")
	assert(#t:floats() == 0, "the help window closes")
	local line = string.match(t:marked(), "|[^\n]*")
	assert(line and string.find(line, "select_to", 1, true), line)
end)

test("esc closes the help window", function(t)
	describe_command(t, "next-word")
	t:keys("esc")
	assert(#t:floats() == 0, "the help window closes")
end)

test("describing a key waits for the keys and shows their command", function(t)
	t:buffer("|abc")
	t:keys("space h k")
	assert(#t:floats() == 0, "nothing shown before a key is pressed")
	t:keys("g")
	assert(#t:floats() == 0, "g starts longer sequences, so it waits for more")
	t:keys("e")
	local help = t:floats()[1]
	assert(help and string.find(help, "goto-last-line", 1, true), help)
	-- The keys described didn't run.
	t:keys("esc")
	t:expect("|abc")
end)

test("describing an unbound key says so", function(t)
	t:buffer("|abc")
	t:keys("space h k")
	t:keys("ctrl-g")
	assert(#t:floats() == 0, "no help window for an unbound key")
	t:expect("|abc")
end)

test("a command without a doc or keys says so, and q closes the help", function(t)
	greed.command({ name = "bare-test-command", run = function() end })
	t:buffer("|abc")
	describe_command(t, "bare-test-command")
	local help = t:floats()[1]
	assert(string.find(help, "(no description)", 1, true), help)
	assert(string.find(help, "Keys: none", 1, true), help)
	t:keys("q")
	assert(#t:floats() == 0, "q closes it")
end)

test(
	"a command bound in several layers lists each, and help opened twice replaces itself",
	function(t)
		greed.keymap.bind("vscode", { ["alt-g"] = "goto-start" })
		describe_command(t, "goto-start")
		local help = t:floats()[1]
		assert(string.find(help, "Keys: g g (helix)", 1, true), help)
		assert(string.find(help, "Keys: alt-g (vscode)", 1, true), help)
		t:keys("esc")
		describe_command(t, "goto-end")
		describe_command(t, "goto-start")
		assert(#t:floats() == 1, "one help window")
	end
)

test("enter does nothing for a command with no file to go to", function(t)
	-- Defined at the REPL, so it has no file.
	assert(
		greed.eval(
			"require('@greed').command({ name = 'no-file-test-command', doc = 'Here', run = function() end })"
		)
	)
	describe_command(t, "no-file-test-command")
	t:keys("enter")
	assert(#t:floats() == 1, "the help stays")
end)

test("a key bound to a missing command says so", function(t)
	greed.keymap.bind("helix", { ["g z"] = "nothing-by-this-name" })
	t:buffer("|abc")
	t:keys("space h k g z")
	local messages = t:messages()
	assert(
		messages[#messages] == "g z runs nothing-by-this-name, which doesn't exist",
		messages[#messages]
	)
end)

test("describing a key works in the mode you're in", function(t)
	t:buffer("|abc")
	greed.mode.set("helix-insert")
	greed.run("describe-key")
	t:keys("esc")
	assert(string.find(t:floats()[1] or "", "normal-mode", 1, true), tostring(t:floats()[1]))
end)

local describe = require("@describe")

test("an option shows its value, default, who set it and where it's defined", function(t)
	t:buffer("|")
	-- Set from a command, so a plugin (this test's) is the one setting it.
	greed.command({
		name = "test-set-width",
		run = function()
			greed.option.set("text-width", 72)
		end,
	})
	t:run("test-set-width")
	local text = describe.text("text-width", "option") :: string
	assert(string.find(text, "Value: 72", 1, true), text)
	assert(string.find(text, "Default: ", 1, true), text)
	assert(string.find(text, "Set by the ", 1, true), text)
	assert(string.find(text, "by the core plugin", 1, true), text)
end)

test("an event shows what its handlers get and who listens", function(t)
	t:buffer("|")
	greed.on("mode.changed", function() end)
	local text = describe.text("mode.changed", "event") :: string
	assert(string.find(text, "Handlers get a ModeChanged", 1, true), text)
	assert(string.find(text, "from: string", 1, true), text)
	assert(string.find(text, "Listening now:", 1, true), text)
end)

test("the API's functions show their signature and doc", function(t)
	t:buffer("|")
	local text = describe.text("greed.option.set", "api") :: string
	assert(
		string.find(
			text,
			"(name: string, value: OptionValue?, opts: { client: boolean? }?) -> ()",
			1,
			true
		),
		text
	)
	local method = describe.text("Buffer:edit", "api") :: string
	assert(string.find(method, "Edits the buffer", 1, true), method)
	-- A signature over several lines is found, and shown whole.
	local grep = describe.text("greed.fs.grep", "api") :: string
	assert(grep and string.find(grep, "pattern: string,", 1, true), grep)
	assert(string.find(grep, "-> ({ GrepLine }?, string?)", 1, true), grep)
end)

test("a plugin's module function says where the plugin's code is", function(t)
	t:buffer("|")
	local text = describe.text("picker.pick") :: string
	assert(text and string.find(text, "picker is a plugin", 1, true), text)
	assert(string.find(text, greed.plugin.dirs().picker .. "/init.luau", 1, true), text)
	assert(describe.text("nosuchplugin.pick") == nil)
end)

test("a plugin says where it's from and what it defines; a mode lists its keys", function(t)
	t:buffer("|")
	local plugin = describe.text("picker", "plugin") :: string
	assert(string.find(plugin, "Loaded from ", 1, true), plugin)
	assert(string.find(plugin, "May use fs.read", 1, true), plugin)
	local mode = describe.text("helix", "mode") :: string
	assert(string.find(mode, "w  next-word", 1, true), mode)
	assert(describe.text("no-such-thing") == nil)
end)

test("space h h describes anything from one picker", function(t)
	t:buffer("|")
	t:keys("space h h")
	t:keys((string.gsub("option text-width", ".", function(c)
		return if c == " " then "space " else c .. " "
	end)))
	t:keys("enter")
	local help = t:floats()[1]
	assert(help and string.find(help, "text-width  (option)", 1, true), help)
end)

test("an option with choices lists them", function()
	local text = describe.text("line-numbers", "option") :: string
	assert(string.find(text, 'Choices: "absolute", "relative", "hybrid"', 1, true), text)
end)

test("a type is found by its name alone, and as the list of names writes it", function(t)
	t:buffer("|")
	local text = describe.text("ThemeEntry") :: string
	assert(text and string.find(text, "type ThemeEntry", 1, true), tostring(text))
	assert(string.find(text, "tui: Style?", 1, true), text)
	local style = describe.text("Style") :: string
	assert(style and string.find(style, "fg: string?", 1, true), tostring(style))
	assert(describe.text("api type ThemeEntry") == text, "as listed")
	assert(describe.text("ThemeEntry", "api") == text, "as an api name")
end)

-- The inspector's lines, and puts the cursor on the first holding `text`.
local function inspector_line(text: string): number
	local buffer = greed.view():buffer()
	for line = 0, buffer:line_count() - 1 do
		if string.find(buffer:line_text(line), text, 1, true) then
			greed.view():set_cursor(buffer:line_start(line))
			return line
		end
	end
	error(`no line with {text}: {buffer:text()}`)
end

test(
	"space h i with nothing under the cursor inspects the editor; enter goes into an object, backspace comes back",
	function(t)
		t:buffer("|hello")
		local buffer = greed.view():buffer()
		t:keys("space h i")
		local page = t:floats()[1]
		assert(string.find(page, "Greed  (editor:)", 1, true), page)
		assert(string.find(page, "Related", 1, true), page)
		inspector_line(`(buffer:{buffer:id()})`)
		t:keys("enter")
		page = t:floats()[1]
		assert(string.find(page, `(buffer:{buffer:id()})`, 1, true), page)
		assert(string.find(page, "lines", 1, true) and string.find(page, "Actions", 1, true), page)
		t:keys("backspace")
		assert(string.find(t:floats()[1], "(editor:)", 1, true), "back at the editor")
		t:keys("ctrl-i")
		assert(string.find(t:floats()[1], `(buffer:{buffer:id()})`, 1, true), "forward again")
		t:keys("ctrl-o")
		assert(string.find(t:floats()[1], "(editor:)", 1, true), "ctrl-o goes back too")
		t:keys("esc")
		assert(#t:floats() == 0)
	end
)

test("enter on an action in the inspector runs it on the object", function(t)
	local core = require("@core")
	local ran: string? = nil
	core.objects.kind({
		name = "ticket",
		get = function(key)
			return { kind = "ticket", id = `ticket:{key}`, label = key, value = key }
		end,
		inspect = function(key)
			return { status = "open" }
		end,
	})
	core.actions.action({
		kind = "ticket",
		name = "close",
		doc = "Close the ticket",
		run = function(target)
			ran = target.value
		end,
	})
	t:buffer("|")
	require("@describe").inspect(assert(core.objects.get("ticket:A-1")))
	local page = t:floats()[1]
	assert(string.find(page, "status  open", 1, true), page)
	inspector_line("Close the ticket")
	t:keys("enter")
	assert(ran == "A-1", "it ran on the ticket")
	assert(#t:floats() == 0, "and the inspector made way")
	-- It shows among what was done to it, and so does its history.
	require("@describe").inspect(assert(core.objects.get("ticket:A-1")))
	page = t:floats()[1]
	assert(
		string.find(page, "Done to it", 1, true) and string.find(page, "you  close", 1, true),
		page
	)
	t:keys("esc")
	core.objects.act(assert(core.objects.get("ticket:A-1")), "history")
	local listed = table.concat(t:floats(), "\n")
	assert(string.find(listed, "you  close", 1, true), listed)
	t:keys("esc")
end)

test("objects are described by id, for space h h and agents", function(t)
	t:buffer("|hello")
	local buffer = greed.view():buffer()
	local describe = require("@describe")
	local found = false
	for _, entry in describe.entries("object") do
		found = found or entry.name == `buffer:{buffer:id()}`
	end
	assert(found, "listed")
	local text = describe.text(`buffer:{buffer:id()}`) or ""
	assert(string.find(text, "lines", 1, true) and string.find(text, "views", 1, true), text)
end)

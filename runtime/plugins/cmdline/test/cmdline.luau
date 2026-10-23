local test = require("@greed/test")
local greed = require("@greed")
local parse = require("../parse")

-- The command line's prompt, from the float showing it.
local function prompt(t: test.TestContext): string
	local floats = t:floats()
	local text = floats[#floats]
	return string.match(text, "[^\n]*$") :: string
end

local function fails(f: () -> ()): string
	local ok: boolean, err: unknown = pcall(f)
	assert(not ok, "expected an error")
	return tostring(err)
end

test("colon opens the command line and enter runs a command", function(t)
	t:buffer("|abc")
	t:keys(":")
	t:expect_mode("helix-insert")
	assert(prompt(t) == ":", prompt(t))
	t:keys("g o t o - e n d enter")
	t:expect_mode("helix")
	t:expect("abc|")
	assert(#t:floats() == 0, "closed")
end)

test("vim and helix short names work, and ! forces", function(t)
	t:buffer("|abc")
	t:keys("i x esc")
	local err = fails(function()
		t:keys(": q enter")
	end)
	assert(string.find(err, "unsaved changes", 1, true), err)
	assert(not t:quitting(), "refused")
	t:keys(": q ! enter")
	assert(t:quitting(), "forced")
end)

test("unknown commands say so", function(t)
	t:buffer("|abc")
	local err = fails(function()
		t:keys(": n o p e enter")
	end)
	assert(string.find(err, "no command called nope", 1, true), err)
end)

test("matches show above the prompt and tab fills them in", function(t)
	t:buffer("|abc")
	t:keys(": g o t o - e")
	local floats = t:floats()
	assert(string.find(floats[#floats], "goto-end  ", 1, true), floats[#floats])
	t:keys("tab")
	assert(prompt(t) == ":goto-end", prompt(t))
	t:keys("enter")
	t:expect("abc|")
end)

test("fewer matches than before all show, none scrolled out of sight", function(t)
	for _, name in { "zq-one", "zq-two" } do
		greed.command({ name = name, doc = "", run = function() end })
	end
	t:buffer("|abc")
	-- A frame after each key, as a client draws them, scrolls the view to
	-- the cursor while there are many matches.
	local screen = ""
	for _, key in { ":", "z", "q" } do
		t:keys(key)
		screen = table.concat(t:screen(80, 24), "\n")
	end
	assert(string.find(screen, "zq-one", 1, true), screen)
	assert(string.find(screen, "zq-two", 1, true), screen)
end)

test("arguments complete by what the command takes", function(t)
	greed.option.define({ name = "tab-width", doc = "Spaces per tab", default = 4 })
	t:buffer("|abc")
	t:keys(": s e t space t a b")
	t:keys("tab")
	assert(prompt(t) == ":set tab-width", prompt(t))
	t:keys("space 2 enter")
	assert(greed.option.get("tab-width") == 2, tostring(greed.option.get("tab-width")))
end)

test("arguments reach the command", function(t)
	t:buffer("|abc")
	t:keys(": e space n o t e s . m d enter")
	local path = greed.view():buffer():path() or ""
	assert(string.sub(path, -9) == "/notes.md", path)
end)

test("lua runs code and = shows values", function(t)
	t:buffer("|abc")
	t:keys(": l u a space x space = space 4 0 enter")
	t:keys(": = space x space + space 2 enter")
	local messages = t:messages()
	assert(messages[#messages] == "42", table.concat(messages, ", "))
end)

test("up and down step through earlier lines starting with what's typed", function(t)
	t:buffer("|abc")
	t:keys(": = space 1 enter")
	t:keys(": g o t o - e n d enter")
	t:keys(": = space 2 enter")
	t:keys(": =")
	t:keys("up")
	assert(prompt(t) == ":= 2", prompt(t))
	t:keys("up")
	assert(prompt(t) == ":= 1", prompt(t))
	t:keys("down down")
	assert(prompt(t) == ":=", prompt(t))
	t:keys("esc")
end)

test("esc and backspace on an empty prompt close it", function(t)
	t:buffer("a|bc")
	t:keys(": esc")
	t:expect_mode("helix")
	assert(#t:floats() == 0, "esc closed")
	t:keys(": backspace")
	t:expect_mode("helix")
	assert(#t:floats() == 0, "backspace closed")
	t:expect("a|bc")
end)

test("words split at spaces, except quoted or escaped ones", function()
	local function words(line: string): string
		return table.concat(parse.words(line), "|")
	end
	assert(words("open  a b") == "open|a|b", words("open  a b"))
	assert(words('open "a b" c') == "open|a b|c", words('open "a b" c'))
	assert(words("open a\\ b") == "open|a b", words("open a\\ b"))
	assert(words("open ''") == "open|", words("open ''"))
	assert(parse.words(parse.quote('say "hi"'))[1] == 'say "hi"', parse.quote('say "hi"'))

	local parsed = parse.parse("q! now") :: parse.Parsed
	assert(parsed.name == "q" and parsed.force and parsed.args[1] == "now", "parsed")
	assert(parse.parse("   ") == nil, "blank")
end)

test("alt-x opens it in the vscode style, where colon types", function(t)
	t:buffer("|abc")
	greed.option.set("editing-style", "vscode")
	t:keys("alt-x")
	t:expect_mode("vscode")
	assert(prompt(t) == ":", prompt(t))
	t:keys("esc")
	assert(#t:floats() == 0, "esc closed it")
	t:expect_mode("vscode")
	greed.option.set("editing-style", "helix")
end)

test(":set parses the value, and text can have spaces", function(t)
	t:buffer("|x")
	greed.option.define({ name = "tab-width", doc = "Spaces per tab", default = 4 })
	t:run("set", { "tab-width", "2" })
	assert(greed.option.get("tab-width") == 2)
	t:run("set", { "jump-label-alphabet", "ab", "cd" })
	assert(
		greed.option.get("jump-label-alphabet") == "ab cd",
		tostring(greed.option.get("jump-label-alphabet"))
	)
	t:run("set", { "jump-label-alphabet", "123" })
	assert(
		greed.option.get("jump-label-alphabet") == "123",
		"a string option keeps a number as text"
	)
	greed.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
	t:run("set", { "tab-width" })
	local messages = t:messages()
	assert(
		messages[#messages] == "tab-width is 2",
		"a name alone shows it: " .. messages[#messages]
	)
	t:run("set", { "tab-width=3" })
	assert(greed.option.get("tab-width") == 3)
	assert(not pcall(function()
		t:run("set")
	end), "an option is needed")
end)

test(":set turns yes-or-no options on, off and over as Vim does", function(t)
	t:buffer("|x")
	greed.option.define({ name = "test-flag", default = false })
	local function set(...: string)
		t:run("set", { ... })
	end
	set("test-flag")
	assert(greed.option.get("test-flag") == true)
	set("notest-flag")
	assert(greed.option.get("test-flag") == false)
	set("test-flag!")
	assert(greed.option.get("test-flag") == true)
	set("invtest-flag")
	assert(greed.option.get("test-flag") == false)
	set("test-flag?")
	local messages = t:messages()
	assert(messages[#messages] == "test-flag is false", messages[#messages])
	t:keys(": t o g g l e space t e s t - f l a g enter")
	assert(greed.option.get("test-flag") == true, ":toggle is Helix's")
	local err = fails(function()
		set("nope")
	end)
	assert(string.find(err, 'no option called "nope"', 1, true), err)
end)

test(":set nu, nonu, rnu and nornu show and hide line numbers as in Vim", function(t)
	t:buffer("|x")
	local buffer = greed.view():buffer()
	local function set(word: string)
		t:keys(": s e t space " .. table.concat(string.split(word, ""), " ") .. " enter")
	end
	set("nonu")
	assert(not buffer:line_numbers(), "hidden")
	set("nu")
	assert(buffer:line_numbers() and greed.option.get("line-numbers") == "absolute")
	set("rnu")
	assert(greed.option.get("line-numbers") == "hybrid", tostring(greed.option.get("line-numbers")))
	set("nonu")
	assert(buffer:line_numbers() and greed.option.get("line-numbers") == "relative")
	set("nornu")
	assert(not buffer:line_numbers(), "both off hides them")
	set("number")
	assert(buffer:line_numbers() and greed.option.get("line-numbers") == "absolute")
end)

test(":w only takes a path after a space; names typed on are names", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "a", ["b.txt"] = "b" })
	greed.run("project", { args = { dir } })
	greed.open(dir .. "/a.txt")
	t:keys("i 1 esc")
	greed.open(dir .. "/b.txt")
	t:keys("i 2 esc")
	t:keys(": w r i t e - a l l enter")
	assert(greed.fs.read(dir .. "/a.txt") == "1a" and greed.fs.read(dir .. "/b.txt") == "2b")
	assert(greed.fs.stat(dir .. "/-all") == nil, "no file called -all")
	for _, typed in { "w f o o", "w - a l l", "w r i t e - n o p e" } do
		local err = fails(function()
			t:keys(": " .. typed .. " enter")
		end)
		assert(string.find(err, "no command called", 1, true), err)
	end
	t:keys(": w a enter : w q a enter")
	assert(t:quitting(), ":wqa quits")
end)

test("Vim's and Helix's buffer commands go through the open files", function(t)
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		["src/one.rs"] = "1",
		["src/two.rs"] = "2",
		["three.md"] = "3",
	})
	greed.run("project", { args = { dir } })
	for _, name in { "src/one.rs", "src/two.rs", "three.md" } do
		greed.open(dir .. "/" .. name)
	end
	local function shown(): string
		return string.sub(greed.view():buffer():path() or "", #dir + 2)
	end
	t:keys(": b space t w o enter")
	assert(shown() == "src/two.rs", shown())
	t:keys(": b # enter")
	assert(shown() == "three.md", shown())
	t:keys("ctrl-^")
	assert(shown() == "src/two.rs", "ctrl-^ too: " .. shown())
	t:keys(": b n enter")
	assert(shown() == "three.md", shown())
	t:keys(": b p enter : b p r e v enter")
	assert(shown() == "src/one.rs", shown())
	t:keys(": b n e x t enter : b u f f e r - p r e v i o u s enter")
	assert(shown() == "src/one.rs", shown())
	local err = fails(function()
		t:keys(": b space s r c enter")
	end)
	assert(string.find(err, "more than one open file matches src", 1, true), err)
	t:keys(": l s enter")
	assert(#t:floats() > 0, ":ls picks a buffer")
	t:keys("esc")
end)

test(":noh, :rla, :only and :tabnew do what they do in Vim and Helix", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a" })
	greed.open(dir .. "/a.txt")
	t:keys(": n o h enter")
	greed.fs.write(dir .. "/a.txt", "changed")
	t:keys(": r l a enter")
	assert(greed.view():buffer():text() == "changed", greed.view():buffer():text())
	t:run("pane-split-right")
	t:keys(": o n l y enter")
	assert(#greed.tab.current().panes == 1)
	t:keys(": t a b n e w enter")
	assert(#greed.tab.list() == 2)
end)

test(":w, :wq and :qa are the usual commands", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a" })
	greed.open(dir .. "/a.txt")
	t:keys("i 1 esc : w enter")
	assert(greed.fs.read(dir .. "/a.txt") == "1a")
	t:keys("i 2 esc : w q enter")
	assert(greed.fs.read(dir .. "/a.txt") == "12a" and t:quitting())
end)

test("shift-tab goes back through the matches, and wraps round", function(t)
	t:buffer("|abc")
	t:keys(": g o t o -")
	t:keys("tab")
	local first = prompt(t)
	t:keys("tab shift-tab")
	assert(prompt(t) == first, prompt(t))
	t:keys("shift-tab")
	assert(
		prompt(t) ~= first and string.find(prompt(t), "goto", 1, true) ~= nil,
		"wrapped to the last: " .. prompt(t)
	)
	t:keys("ctrl-c")
	t:expect_mode("helix")
end)

test("other plugins add completers and aliases", function(t)
	local cmdline = require("@cmdline")
	cmdline.completer("branch", function()
		return { { text = "main" }, { text = "dev" } }
	end)
	local got = nil
	greed.command({
		name = "checkout",
		args = { { name = "branch", complete = "branch" } },
		run = function(ctx)
			got = ctx.args[1]
		end,
	})
	cmdline.alias("co", "checkout")
	t:buffer("|abc")
	t:keys(": c o space d")
	t:keys("tab enter")
	assert(got == "dev", tostring(got))
end)

test("files complete one folder at a time", function(t)
	local dir = t:tempdir({ ["src/main.rs"] = "", ["src/lib.rs"] = "" })
	t:buffer("|abc")
	greed.run("command-line")
	for _, key in string.split(`e {dir}/s`, "") do
		t:keys(if key == " " then "space" else key)
	end
	t:keys("tab")
	assert(prompt(t) == `:e {dir}/src/`, prompt(t))
	t:keys("m tab")
	assert(prompt(t) == `:e {dir}/src/main.rs`, prompt(t))
	t:keys("esc")
end)

test("history skips blank lines and repeats", function(t)
	t:buffer("|abc")
	t:keys(": = space 6 enter : = space 7 enter : = space 7 enter : space enter")
	t:keys(": up")
	assert(prompt(t) == ":= 7", "the blank line isn't kept: " .. prompt(t))
	t:keys("up")
	assert(prompt(t) == ":= 6", "nor the repeat: " .. prompt(t))
	t:keys("esc")
end)

test(":lua with an error says what went wrong, and := shows nil", function(t)
	t:buffer("|abc")
	local err = fails(function()
		t:keys(": l u a space e r r o r ( ' b a d ' ) enter")
	end)
	assert(string.find(err, "bad", 1, true), err)
	t:keys(": = space n i l enter")
	local messages = t:messages()
	assert(messages[#messages] == "nil", tostring(messages[#messages]))
end)

test("paths complete from the home folder, and hidden ones once a dot is typed", function(t)
	local home = greed.fs.dirs().home :: string
	greed.fs.write(home .. "/projects/a.txt", "")
	greed.fs.write(home .. "/.config/greed.luau", "")
	t:buffer("|abc")
	t:keys(": e space ~ / p r tab")
	assert(prompt(t) == ":e ~/projects/", prompt(t))
	t:keys("esc : e space ~ / . c tab")
	assert(prompt(t) == ":e ~/.config/", prompt(t))
	t:keys("esc")
end)

test("an option's value completes from its choices", function(t)
	greed.option.define({
		name = "test-look",
		default = "plain",
		choices = { "plain", "fancy" },
	})
	t:buffer("|abc")
	t:keys(": s e t space t e s t - l o o k space f")
	t:keys("tab")
	assert(prompt(t) == ":set test-look fancy", prompt(t))
	t:keys("enter")
	assert(greed.option.get("test-look") == "fancy")
end)

test("a yes-or-no option's value completes to true or false", function(t)
	greed.option.define({ name = "test-flag", default = false })
	t:buffer("|abc")
	t:keys(": s e t space t e s t - f l a g space t")
	t:keys("tab")
	assert(prompt(t) == ":set test-flag true", prompt(t))
end)

test("a command line whose view closes some other way leaves nothing behind", function(t)
	local cmdline = require("@cmdline")
	t:buffer("|abc")
	local shown: { string } = {}
	cmdline.completer("test-color", function()
		return { { text = "red" }, { text = "blue" } }
	end, function(name: string?)
		table.insert(shown, name or "undone")
	end)
	greed.command({
		name = "test-paint",
		args = { { name = "color", complete = "test-color" } },
		run = function() end,
	})
	t:keys(": t e s t - p a i n t space tab")
	assert(shown[1] == "red", shown[1])
	greed.view():close()
	t:wait(0)
	t:expect_mode("helix")
	assert(shown[2] == "undone", "the preview is undone")
	t:run("command-line-run")
	assert(#shown == 2, "nothing left to run")
	t:keys(": g o t o - e n d enter")
	t:expect("abc|")
end)

test("each client types in a command line of its own", function(t)
	t:buffer("|abc")
	local second = t:client()
	second:keys(": g o t o")
	assert(#t:floats() == 0, "the first isn't shown the second's")
	t:keys(":")
	assert(prompt(t) == ":", prompt(t))
	second:keys("- e n d enter")
	second:expect("abc|")
	t:expect_mode("helix-insert")
	t:keys("g o t o - e n d enter")
	t:expect("abc|")
	assert(#t:floats() == 0, "closed")
end)

test(
	":set takes Vim's case names, says how indent goes, and a number of spaces for indent",
	function(t)
		t:buffer("|x")
		local case = greed.option.get("search-case")
		t:run("set", { "ic" })
		assert(greed.option.get("search-case") == "ignore")
		t:run("set", { "scs" })
		assert(greed.option.get("search-case") == "smart")
		t:run("set", { "noic" })
		assert(greed.option.get("search-case") == "match")
		greed.option.set("search-case", case)
		local ok, err = pcall(function()
			t:run("set", { "sw=2" })
		end)
		assert(
			not ok and string.find(tostring(err), "indent is per language", 1, true),
			tostring(err)
		)
		local indent = greed.option.get("indent")
		t:run("set", { "indent", "2" })
		assert(greed.option.get("indent") == "  ", tostring(greed.option.get("indent")))
		greed.option.set("indent", indent)
	end
)

test(":!cmd runs in the project's shell, and :%!cmd puts the lines through it", function(t)
	-- Needs the pipe and shell plugins, which the command line runs without.
	local have: { [string]: boolean } = {}
	for _, command in greed.commands() do
		have[command.name] = true
	end
	if not (have.pipe and have["shell-line"]) then
		return
	end
	t:buffer("b\na\n|c")
	t:keys(": % ! s o r t enter")
	t:wait_for(function()
		return greed.view():buffer():text() == "a\nb\nc\n"
			or greed.view():buffer():text() == "a\nb\nc"
	end)
	t:keys(": ! e c h o space h i enter")
	t:wait_for(function()
		return greed.view():buffer():kind() == "shell"
	end)
end)

test("matches keep one row each, their docs cut to fit, so the best ones show", function(t)
	t:buffer("|x")
	greed.command({
		name = "zzbest",
		doc = string.rep("a long description that would wrap ", 6),
		run = function() end,
	})
	t:keys(": z z b")
	t:screen(80, 24)
	t:keys("e")
	local floats = t:floats()
	local text = floats[#floats]
	assert(string.find(text, " zzbest  a long description", 1, true), text)
	assert(string.find(text, "…", 1, true), "cut, with an ellipsis")
	t:keys("esc")
end)

-- Types the keys for `text` on the command line, a character at a time.
local function type_line(t: test.TestContext, text: string)
	for _, key in string.split(text, "") do
		t:keys(if key == " " then "space" else key)
	end
end

test("typed arguments complete from their type", function(t)
	local core = require("@core")
	core.objects.kind({
		name = "test-fruit",
		list = function()
			return {
				{ kind = "test-fruit", id = "test-fruit:apple", label = "apple", value = "apple" },
				{
					kind = "test-fruit",
					id = "test-fruit:7",
					label = "blood orange",
					value = "orange",
				},
			}
		end,
	})
	local got: { [string]: any } = {}
	local args: { greed.ArgSpec } = {
		{ name = "size", type = "choice", choices = { "small", "large" } },
		{ name = "ripe", type = "boolean" },
		{ name = "fruit", type = "object", kind = "test-fruit" },
		{ name = "dir", type = "folder", optional = true },
	}
	greed.command({
		name = "test-typed",
		args = args,
		run = function(ctx)
			got = ctx.values
		end,
	})
	local dir = t:tempdir({ ["src/main.rs"] = "", ["notes.md"] = "" })
	t:buffer("|abc")
	greed.run("command-line")
	type_line(t, "test-typed l")
	t:keys("tab")
	assert(prompt(t) == ":test-typed large", prompt(t))
	type_line(t, " f")
	t:keys("tab")
	assert(prompt(t) == ":test-typed large false", prompt(t))
	type_line(t, " ap")
	t:keys("tab")
	assert(prompt(t) == ":test-typed large false apple", prompt(t))
	type_line(t, ` {dir}/`)
	t:keys("tab")
	-- Folders only: notes.md isn't offered.
	assert(prompt(t) == `:test-typed large false apple {dir}/src/`, prompt(t))
	t:keys("enter")
	assert(got.size == "large" and got.ripe == false, tostring(got.size))
	assert(got.fruit.id == "test-fruit:apple", tostring(got.fruit and got.fruit.id))
	assert(got.dir == `{dir}/src`, tostring(got.dir))

	-- A label with spaces completes as its key, which finds it too.
	greed.run("command-line")
	type_line(t, "test-typed small on 7")
	t:keys("tab")
	assert(prompt(t) == ":test-typed small on 7", prompt(t))
	t:keys("enter")
	assert(got.fruit.label == "blood orange", tostring(got.fruit and got.fruit.label))
end)

test("a typed command's wrong arguments say its usage", function(t)
	greed.command({
		name = "test-count",
		args = { { name = "n", type = "number" } },
		run = function() end,
	})
	t:buffer("|abc")
	local err = fails(function()
		greed.run("command-line")
		type_line(t, "test-count abc")
		t:keys("enter")
	end)
	assert(string.find(err, ':test-count N: "abc" isn\'t a number', 1, true), err)
end)

test(":get and :toggle need an option", function(t)
	t:buffer("|abc")
	local err = fails(function()
		t:run("get-option")
	end)
	assert(string.find(err, ":get-option OPTION: needs OPTION", 1, true), err)
	greed.option.define({ name = "test-switch", default = false })
	t:run("toggle-option", { "test-switch" })
	assert(greed.option.get("test-switch") == true)
end)

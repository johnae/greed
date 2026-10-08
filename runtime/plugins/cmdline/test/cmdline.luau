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
	greed.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
	assert(not pcall(function()
		t:run("set", { "tab-width" })
	end), "a value is needed")
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

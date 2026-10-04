local test = require("@greed/test")
local greed = require("@greed")

test(":macro-save turns the last macro into a command that plays it", function(t)
	t:buffer("|one\ntwo\n")
	-- Record: go to the end of the line and add a "!".
	t:keys("Q g l a ! esc Q")
	t:run("macro-save", { "shout" })
	local file = (greed.fs.dirs().config :: string) .. "/plugins/macros/init.luau"
	local text = greed.fs.read(file) :: string
	assert(string.find(text, 'name = "shout"', 1, true), text)
	assert(string.find(text, 'greed.keys.feed("g l a ! esc")', 1, true), text)
	assert(greed.view():buffer():path() == file, "the file opens to edit")
	-- The command works at once.
	t:buffer("|abc\n")
	t:run("shout")
	t:expect("abc|!\n")
end)

test(":macro-save says why when it can't", function(t)
	t:buffer("|x\n")
	t:run("macro-save", { "nothing" })
	local messages = t:messages()
	assert(messages[#messages] == "can't save it: no macro in @@", messages[#messages])
	t:keys("Q x Q")
	t:run("macro-save", { "Bad Name" })
	messages = t:messages()
	assert(
		string.find(messages[#messages], "lowercase words with dashes", 1, true),
		messages[#messages]
	)
	t:run("macro-save", { "twice" })
	t:buffer("|x\n")
	t:run("macro-save", { "twice" })
	messages = t:messages()
	assert(
		string.find(messages[#messages], "already has a command called twice", 1, true),
		messages[#messages]
	)
end)

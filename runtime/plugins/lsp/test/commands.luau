local test = require("@greed/test")

test("without a language server, hover and g d say so", function(t)
	t:buffer("|plain text")
	t:keys("space k")
	local messages = t:messages()
	assert(messages[#messages] == "no language server for this buffer", messages[#messages])
	t:keys("g d")
	messages = t:messages()
	assert(messages[#messages] == "no language server for this buffer", messages[#messages])
end)

test("space d with no problems says so", function(t)
	t:buffer("|plain text")
	t:keys("space d")
	local messages = t:messages()
	assert(messages[#messages] == "no problems", messages[#messages])
end)

test("a file whose language has no server says so too", function(t)
	local greed = require("@greed")
	local dir = t:tempdir({ ["notes.zz"] = "hello" })
	greed.open(dir .. "/notes.zz")
	t:keys("space k")
	local messages = t:messages()
	assert(string.find(messages[#messages], "no language server", 1, true), messages[#messages])
end)

test("a language whose server isn't installed says which program is missing", function(t)
	local greed = require("@greed")
	greed.filetype("zzlang", { extensions = { "zzl" } })
	greed.lsp.server({ language = "zzlang", commands = { { "greed-test-no-such-server" } } })
	local dir = t:tempdir({ ["notes.zzl"] = "hello" })
	greed.open(dir .. "/notes.zzl")
	t:keys("g d")
	local messages = t:messages()
	assert(
		messages[#messages]
			== "no language server for zzlang: greed-test-no-such-server isn't installed",
		messages[#messages]
	)
	greed.lsp.remove("zzlang")
end)

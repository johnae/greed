local test = require("@kern/test")
local kern = require("@kern")
local approvals = require("@approvals")

test("a plugin's capabilities read as what it may do", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "runner"\ncapabilities = ["proc", "fs.read"]\n',
		["init.luau"] = "return {}\n",
	})
	local about = kern.plugin.describe(dir)
	assert(about.name == "runner" and #about.missing == 0, about.name)
	local lines = approvals.lines(about)
	assert(lines[1] == "It asks to:", lines[1])
	assert(lines[2] == "  proc: run programs, which can do anything you can", lines[2])
	assert(lines[3] == "  fs.read: read any file, by path", lines[3])
end)

test("a plugin using nothing beyond the editor says so", function(t)
	local dir = t:tempdir({ ["plugin.toml"] = 'name = "plain"\n', ["init.luau"] = "return {}\n" })
	assert(approvals.lines(kern.plugin.describe(dir))[1] == "It uses nothing beyond the editor.")
end)

test(":plugins-approve says when nothing waits", function(t)
	t:buffer("|x")
	t:run("plugins-approve")
	local messages = t:messages()
	assert(messages[#messages] == "no plugins wait for approval", messages[#messages])
end)

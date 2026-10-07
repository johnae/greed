local test = require("@greed/test")
local greed = require("@greed")

test("t:repo makes a repository with its files committed, and runs git there", function(t)
	if greed.which("git") == nil then
		return
	end
	local dir, git = t:repo("git", { ["a.txt"] = "a\n", ["b.bin"] = "\0\x89" })
	assert(git("log", "--format=%an %s") == "t first\n", git("log", "--format=%an %s"))
	assert(git("show", "HEAD:b.bin") == "\0\x89", "output comes back as it was printed")
	assert(greed.fs.read(dir .. "/a.txt") == "a\n")
	local ok: boolean, err: unknown = pcall(git, "no-such-command")
	assert(not ok and string.find(tostring(err), "git no-such-command:", 1, true), tostring(err))
end)

test("without files, t:repo only makes the repository", function(t)
	if greed.which("jj") == nil then
		return
	end
	local _, jj = t:repo("jj")
	local log = jj("log", "--no-graph", "-r", "::@ ~ root()", "-T", "description")
	assert(log == "", log)
end)

test("t:vcs runs jj or git in a folder of your own", function(t)
	if greed.which("git") == nil then
		return
	end
	local dir = t:tempdir({ ["repo/a.txt"] = "a\n" })
	local git = t:vcs("git", dir .. "/repo")
	git("init", "-q")
	assert(greed.fs.stat(dir .. "/repo/.git"), "it ran in the folder")
end)

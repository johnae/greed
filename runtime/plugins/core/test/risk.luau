local test = require("@greed/test")
local core = require("@core")

local risk = core.risk

test("command lines that change or destroy something say why; the rest say nothing", function()
	for _, line in
		{
			"ls -la",
			"git status",
			"git log --oneline | head",
			"curl https://example.com",
			"jj log",
			"FOO=1 echo hi",
		}
	do
		assert(risk.of(line) == nil, line)
	end
	local cases: { [string]: string } = {
		["rm -rf build"] = "deletes",
		["sudo rm -r /tmp/x"] = "deletes",
		["git push --force origin main"] = "pushes over",
		["git push"] = "sends commits",
		["make && git reset --hard HEAD~1"] = "throws away",
		["curl -X DELETE https://api/x"] = "DELETE",
		["curl -XPOST https://api/x"] = "POST",
		["curl --data '{}' https://api/x"] = "sends data",
		["echo $(kill 12)"] = "stops",
		["env FOO=1 terraform apply"] = "infrastructure",
		["jj git push"] = "sends changes",
	}
	for line, says in cases do
		local why = risk.of(line)
		assert(why and string.find(why, says, 1, true), `{line}: {why}`)
	end
end)

test("a plugin's rules go with it", function(t)
	local greed = require("@greed")
	local dir = t:tempdir({
		["frob/plugin.toml"] = 'name = "frob"\nrequires = ["core"]\n',
		["frob/init.luau"] = 'require("@core").risk.rule("frob", function() return "frobs" end)\nreturn {}\n',
	})
	greed.plugin.load(dir .. "/frob")
	assert(risk.of("frob it") == "frobs", tostring(risk.of("frob it")))
	greed.plugin.unload("frob")
	assert(risk.of("frob it") == nil)
end)

test("command lines that only look, or build and test, are safe; anything else isn't", function()
	for _, line in
		{
			"ls -la",
			"rg -n 'fn draw' crates | head -30",
			"git log --oneline -5 && git status",
			"git -C sub diff HEAD~1",
			"jj log --limit 3; jj st",
			"sed -n '10,20p' src/main.rs",
			"find . -name '*.rs' | wc -l",
			"cargo test -q -p greed-core 2>&1 | tail",
			"grep -rn x src >/dev/null",
			"cat $(ls *.md)",
			"cd crates && ls",
		}
	do
		assert(risk.safe(line), line)
	end
	for _, line in
		{
			"rm x",
			"ls > files.txt",
			"cat a >> b",
			"sed -i 's/a/b/' x",
			"sed -i.bak 's/a/b/' x",
			"find . -name '*.o' -delete",
			"find . -exec rm {} +",
			"git push",
			"git branch -D old",
			"jj abandon",
			"cargo clippy --fix",
			"sort -o out.txt in.txt",
			"ls | xargs rm",
			"cat $(rm x)",
			"sudo ls",
			"python3 script.py",
			"echo hi | tee out",
			"",
		}
	do
		assert(not risk.safe(line), line)
	end
end)

test("a plugin says which of its program's commands are safe", function(t)
	local greed = require("@greed")
	local dir = t:tempdir({
		["frob/plugin.toml"] = 'name = "frob"\nrequires = ["core"]\n',
		["frob/init.luau"] = 'require("@core").risk.safe_when("frob", function(words) '
			.. 'return words[2] == "show" end)\nreturn {}\n',
	})
	assert(not risk.safe("frob show"))
	greed.plugin.load(dir .. "/frob")
	assert(risk.safe("frob show") and not risk.safe("frob burn"))
	greed.plugin.unload("frob")
	assert(not risk.safe("frob show"))
end)

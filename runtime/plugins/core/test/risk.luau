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

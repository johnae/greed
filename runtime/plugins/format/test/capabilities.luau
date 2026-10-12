local test = require("@greed/test")
local greed = require("@greed")

-- A plugin called `name` in a folder of its own, using `requires`, whose
-- command NAME-go runs `body` and says "ok" or the error.
local function plugin(t: test.TestContext, name: string, body: string): string
	return t:tempdir({
		["plugin.toml"] = `name = "{name}"\nrequires = ["languages"]\n`,
		["init.luau"] = `local greed = require("@greed")\n`
			.. `greed.command(\{ name = "{name}-go", run = function(ctx)\n`
			.. `  local ok, err = pcall(function() {body} end)\n`
			.. `  greed.echo(if ok then "ok" else tostring(err))\n`
			.. `end \})\n`,
	})
end

local function last(t: test.TestContext): string
	local messages = t:messages()
	return messages[#messages]
end

test("a formatter a plugin sets runs as that plugin may, not as the format plugin", function(t)
	local dir = t:tempdir({ ["a.luau"] = "x\n" })
	local marker = `{dir}/ran`
	local body = `local entry = require("@languages").get("luau") entry.formatter = \{ "sh", "-c", "touch {marker}" \} `
		.. `require("@languages").set("luau", \{ formatter = \{ "sh", "-c", "touch {marker}; cat" \} \})`
	greed.plugin.load(plugin(t, "formatter-setter", body))
	t:run("formatter-setter-go")
	-- Trusted, so formatting on save would run if the plugin may.
	require("@core").project.trust(dir)
	greed.open(`{dir}/a.luau`)
	t:run("save")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "formatter-setter", 1, true), said)
	assert(greed.fs.stat(marker) == nil, "the formatter didn't run")
	require("@languages").set("luau", { formatter = { "stylua", "-" } })
end)

test("a plugin without proc can't give a language a server to start", function(t)
	t:buffer("|x")
	local before = require("@languages").get("rust")
	local body = 'require("@languages").set("rust", { servers = { { "sh", "-c", "evil" } } })'
	greed.plugin.load(plugin(t, "server-setter", body))
	t:run("server-setter-go")
	local said = last(t)
	assert(string.find(said, "server-setter", 1, true) and string.find(said, "proc", 1, true), said)
	local now = require("@languages").get("rust")
	assert(
		now and before and now.servers and now.servers[1][1] == (before.servers :: any)[1][1],
		"unchanged"
	)
end)

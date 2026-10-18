local test = require("@greed/test")
local greed = require("@greed")
local plugins = require("@git-plugins")

-- Runs `f` as a command, where waiting on programs works.
local function waiting(t: test.TestContext, f: () -> ())
	greed.command({
		name = "test-git-plugins",
		run = function()
			f()
		end,
	})
	t:run("test-git-plugins")
end

-- Runs git in `dir`, failing the test if it fails.
local function git(dir: string, args: { string }): string
	local command = { "git", "-c", "user.name=test", "-c", "user.email=test@example.com" }
	table.move(args, 1, #args, #command + 1, command)
	local ran = assert(greed.process.run(command, { cwd = dir }))
	assert(ran.code == 0, ran.stderr)
	return (string.gsub(ran.stdout, "%s+$", ""))
end

-- A repository holding a plugin called `name`, with one commit; returns
-- its folder and that commit.
local function repository(t: test.TestContext, name: string): (string, string)
	local dir = t:tempdir({
		["plugin.toml"] = `name = "{name}"\n`,
		["init.luau"] = "return {}\n",
	})
	git(dir, { "init", "--quiet", "--initial-branch=main" })
	git(dir, { "add", "-A" })
	git(dir, { "commit", "--quiet", "-m", "first" })
	return dir, git(dir, { "rev-parse", "HEAD" })
end

test("a plugin's name comes from where it's fetched from", function()
	assert(plugins.name_of("https://github.com/someone/greed-jump.git") == "jump")
	assert(plugins.name_of("git@github.com:someone/todo") == "todo")
	assert(plugins.name_of("/home/me/src/thing/") == "thing")
end)

test("the lock file reads back what it pins", function()
	local locked = plugins.parse_lock(
		"# pins\njump https://x/greed-jump main abc123\ntodo /src/todo - def456\n"
	)
	assert(locked.jump.url == "https://x/greed-jump" and locked.jump.ref == "main")
	assert(locked.jump.commit == "abc123")
	assert(locked.todo.ref == nil and locked.todo.commit == "def456")
end)

test(
	"sync fetches a plugin at the lock file's commit; update moves it on and pins that",
	function(t)
		local repo, first = repository(t, "hello")
		local lock = `{t:tempdir()}/plugins.lock`
		greed.option.set("plugins-lock", lock)
		plugins.use(repo, { name = "hello" })
		local dir = `{plugins.folder()}/hello`
		waiting(t, function()
			plugins.sync()
		end)
		assert(greed.fs.stat(`{dir}/plugin.toml`), "fetched")
		assert(
			string.find(greed.fs.read(lock) or "", `hello {repo} - {first}`, 1, true),
			(greed.fs.read(lock))
		)
		-- A new commit there: sync keeps the pin, update takes it.
		greed.fs.write(`{repo}/init.luau`, "return { two = true }\n")
		git(repo, { "commit", "--quiet", "-am", "second" })
		local second = git(repo, { "rev-parse", "HEAD" })
		waiting(t, function()
			plugins.sync()
		end)
		assert(git(dir, { "rev-parse", "HEAD" }) == first, "pinned")
		waiting(t, function()
			plugins.sync(true)
		end)
		assert(git(dir, { "rev-parse", "HEAD" }) == second, "updated")
		assert(string.find(greed.fs.read(lock) or "", second, 1, true), "pinned again")
		greed.option.set("plugins-lock", "")
	end
)

test("another machine's sync fetches the pinned commit, not the latest", function(t)
	local repo, first = repository(t, "pinned")
	greed.fs.write(`{repo}/init.luau`, "return { two = true }\n")
	git(repo, { "commit", "--quiet", "-am", "second" })
	local lock = `{t:tempdir()}/plugins.lock`
	greed.fs.write(lock, `pinned {repo} - {first}\n`)
	greed.option.set("plugins-lock", lock)
	plugins.use(repo, { name = "pinned" })
	waiting(t, function()
		plugins.sync()
	end)
	assert(git(`{plugins.folder()}/pinned`, { "rev-parse", "HEAD" }) == first)
	greed.option.set("plugins-lock", "")
end)

local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A plugin called `name` declaring `capabilities`, whose command NAME-go
-- opens a shell in `dir` and runs `line` there with `options` (Luau),
-- saying the error if shell.run raised one.
local function plugin(
	t: test.TestContext,
	name: string,
	capabilities: string,
	dir: string,
	line: string,
	options: string
)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = `name = "{name}"\nrequires = ["shell"]\ncapabilities = [{capabilities}]\n`,
		["init.luau"] = `local greed = require("@greed")\n`
			.. `local shell = require("@shell")\n`
			.. `greed.command(\{ name = "{name}-go", run = function()\n`
			.. `  local sh = shell.open(\{ cwd = {string.format("%q", dir)}, show = false \})\n`
			.. `  local ok, err = pcall(shell.run, sh, {string.format("%q", line)}, {options})\n`
			.. `  if not ok then greed.echo(tostring(err)) end\n`
			.. `end \})\n`,
	}))
end

-- Runs NAME-go and gives back the block it made, once it finished.
local function ran(t: test.TestContext, name: string): Block
	t:buffer("|")
	t:run(`{name}-go`)
	local shells = shell.list()
	local sh = shells[#shells]
	assert(sh and #sh.blocks > 0, `no block: {table.concat(t:messages(), "\n")}`)
	local block = sh.blocks[#sh.blocks]
	t:wait_for(function()
		return block.status ~= "running"
	end, 5000)
	return block
end

test("a plugin with proc runs lines through the shell, which keeps its own files", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	-- A pipe goes to a real shell, whose wrapper keeps the folder and the
	-- variables in the cache folder; that's the shell's, not the plugin's.
	plugin(t, "piper", '"proc"', dir, "echo hi | tr h H", '{ by = "agent", runner = "pipe" }')
	local piped = ran(t, "piper")
	assert(piped.status == "done", `{piped.status}: {piped.stderr}`)
	assert(piped.stdout == "Hi\n", piped.stdout)

	-- Run as a user's line: history, a terminal, and cd carried over.
	plugin(t, "mover", '"proc"', dir, "cd sub && pwd", "nil")
	local moved = ran(t, "mover")
	assert(moved.status == "done", `{moved.status}: {moved.output}`)
	assert(moved.cwd_after == `{dir}/sub`, tostring(moved.cwd_after))
end)

test("a plugin without proc gets a failed block saying why, never a running one", function(t)
	local dir = t:tempdir()
	plugin(t, "plain", "", dir, "echo hi | tr h H", '{ by = "agent", runner = "pipe" }')
	local block = ran(t, "plain")
	assert(block.status == "failed", block.status)
	assert(string.find(block.stderr, 'add "proc"', 1, true), block.stderr)
end)

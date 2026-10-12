local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A shell in a folder holding `files`.
local function opened(t: test.TestContext, files: { [string]: string }): Shell
	greed.option.set("shell-fallback", "sh")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir(files)
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

test("data reads a source into the block's table, its columns in order", function(t)
	local sh = opened(t, { ["sales.csv"] = "region,units\nnorth,12\nsouth,7\n" })
	local block = ran(t, sh, "data csv path=sales.csv")
	assert(block.code == 0, block.output)
	local tbl = assert(block.table, block.output)
	assert(table.concat(tbl.columns, ",") == "region,units", table.concat(tbl.columns, ","))
	assert(tbl.rows[2].region == "south" and tbl.rows[2].units == "7")
	-- Stages after it read the same table.
	local some = ran(t, sh, "data csv path=sales.csv | where units > 10")
	local rows = assert(some.table).rows
	assert(#rows == 1 and rows[1].region == "north", some.output)
end)

test("data says what's wrong, and fails", function(t)
	local sh = opened(t, {})
	local block = ran(t, sh, "data nosuch")
	assert(
		block.code ~= 0 and string.find(block.output, "no data source called nosuch", 1, true),
		block.output
	)
	block = ran(t, sh, "data")
	assert(block.code ~= 0 and string.find(block.output, "which source", 1, true), block.output)
end)

test("a query's @name is the shell's variable, bound as a parameter", function(t)
	if greed.which("sqlite3") == nil then
		return
	end
	local sh = opened(t, {})
	assert(greed.process.run({ "sqlite3", `{sh.cwd}/shop.db` }, {
		stdin = "create table c(name text, city text);\n"
			.. "insert into c values ('ann', 'oslo'), ('bob', 'rome');\n",
	}))
	ran(t, sh, "export city=rome")
	local block = ran(t, sh, 'data sqlite db=shop.db "SELECT name FROM c WHERE city = @city"')
	local rows = assert(block.table, block.output).rows
	assert(#rows == 1 and rows[1].name == "bob", block.output)
end)

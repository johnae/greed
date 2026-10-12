-- Data sources in the Greed shell: `data SOURCE [KEY=VALUE...] [QUERY]`
-- reads a table from one (see `core.data`), its `@name`s the shell's
-- variables, bound as parameters:
--
--     export city=oslo
--     data sqlite db=shop.db "SELECT name, total FROM customers WHERE city = @city"
--     data csv path=sales.csv | where units > 10 | chart bar units
--
-- Its table is the block's, columns in the order the source gives them,
-- so table stages, `| chart`, `watch`, a board's cards and a Markdown
-- ```` ```shell ```` block all read databases and files this way.

local core = require("@core")
local shell = require("@shell")
local sources = require("./sources")

local M = {}

-- The table each block read, for the shell to take as it is rather than
-- read back from the lines it printed.
local read: { [any]: shell.Table } = setmetatable({}, { __mode = "k" }) :: any

--- `args` (what follows `data`) as the source's name and what it's asked:
--- `KEY=VALUE` settings, then the rest as its text. Nil and why without a
--- source.
function M.ask(args: { string }, dir: string): (string?, core.DataAsk?, string?)
	local name = args[1]
	if name == nil then
		return nil, nil, "data SOURCE [KEY=VALUE...] [QUERY]: which source?"
	end
	local settings: { [string]: string } = {}
	local i = 2
	while args[i] do
		local key, value = string.match(args[i], "^([%a_][%w_]*)=(.*)$")
		if key == nil or value == nil then
			break
		end
		settings[key] = value
		i += 1
	end
	local body = table.concat(table.move(args, i, #args, 1, {}), " ")
	return name, { args = settings, body = body, values = {}, dir = dir }, nil
end

shell.builtin({
	name = "data",
	usage = "data SOURCE [KEY=VALUE...] [QUERY]",
	doc = "Read a table from a data source: csv, sqlite, psql and those plugins add; @name in a query is the shell's variable",
	args = "path",
}, function(args, ctx)
	local name, ask, why = M.ask(args, ctx.cwd)
	if name == nil or ask == nil then
		ctx.error((why or "") .. "\n")
		return 2
	end
	local editor = shell.editor_environment()
	-- The shell's own variables, then its folder's, then the editor's; one
	-- the shell unset (false) is empty.
	for _, param in sources.params(ask.body) do
		local value: string | false | nil = ctx.block.env[param]
		if value == nil then
			value = ctx.block.provided[param]
		end
		if value == nil then
			value = editor[param]
		end
		ask.values[param] = if value then value else nil
	end
	local t, failed = core.data.read(name, ask)
	if t == nil then
		ctx.error((failed or "nothing to read") .. "\n")
		return 1
	end
	local text = core.data.text(t)
	read[ctx.block] = { columns = text.columns, rows = text.rows }
	if #text.columns > 0 then
		ctx.write(shell.tables.text(read[ctx.block]))
	end
	return 0
end)

shell.parser("data", function(_text: string, block: any): any
	return read[block]
end)

return M

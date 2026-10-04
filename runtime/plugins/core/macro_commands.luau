-- Macros as commands: `:macro-save NAME` turns the last macro into a
-- command of its own, written to a `macros` plugin in your config (or in
-- Greed's data folder when the config can't be written) and loaded at once.
-- The file opens so you can edit what it does, or ask an agent to rewrite
-- the keys as real code.
local greed = require("@greed")
local registers = require("./registers")

local M = {}

local HEADER = [[
-- Commands saved from macros with :macro-save. Each plays the keys it was
-- recorded with; edit them into real code whenever you like.
local greed = require("@greed")
]]

local function name_field(name: string): string
	return `name = {string.format("%q", name)}`
end

-- The `macros` plugin's folder: in the config if it can be written there,
-- otherwise in the data folder. Creates it when it isn't there yet.
local function plugin_dir(): (string?, string?)
	local dirs = greed.fs.dirs()
	for _, base in { dirs.config, dirs.data } do
		if base then
			local dir = `{base}/plugins/macros`
			if greed.fs.stat(`{dir}/init.luau`) then
				return dir, nil
			end
			local ok = greed.fs.write(`{dir}/plugin.toml`, 'name = "macros"\n')
				and greed.fs.write(`{dir}/init.luau`, HEADER)
			if ok then
				return dir, nil
			end
		end
	end
	return nil, "neither the config folder nor the data folder can be written"
end

--- The Luau for a command `name` that plays `keys`.
function M.source(name: string, keys: string): string
	return table.concat({
		"",
		"greed.command({",
		`	{name_field(name)},`,
		`	doc = {string.format("%q", "Plays the keys " .. keys)},`,
		"	run = function()",
		`		greed.keys.feed({string.format("%q", keys)})`,
		"	end,",
		"})",
		"",
	}, "\n")
end

--- Saves the macro in register `register` as the command `name`, loads it,
--- and returns the file it's in, or nil and why not.
function M.save(name: string, register: string): (string?, string?)
	if not string.match(name, "^[a-z][a-z0-9-]*$") then
		return nil, "a command name is lowercase words with dashes, like fix-imports"
	end
	local keys = registers.macro(register)
	if keys == nil or keys == "" then
		return nil, `no macro in @{register}`
	end
	local dir, err = plugin_dir()
	if dir == nil then
		return nil, err
	end
	local file = `{dir}/init.luau`
	local text = greed.fs.read(file) or HEADER
	if string.find(text, name_field(name), 1, true) then
		return nil, `{file} already has a command called {name}`
	end
	local ok, problem = greed.fs.write(file, text .. M.source(name, keys))
	if not ok then
		return nil, problem
	end
	greed.plugin.load(dir)
	return file, nil
end

greed.command({
	name = "macro-save",
	doc = "Save the last macro (or the one in a register) as a command you can run and edit",
	args = {
		{ name = "name", doc = "What to call the command" },
		{ name = "register", doc = "The register the macro is in; @ if left out" },
	},
	run = function(ctx)
		local name = ctx.args[1]
		if name == nil then
			greed.echo("give the command a name: :macro-save NAME")
			return
		end
		local file, err = M.save(name, ctx.args[2] or "@")
		if file == nil then
			greed.echo(`can't save it: {err}`)
			return
		end
		greed.open(file)
		local view = greed.view()
		local buffer = view:buffer()
		local at = string.find(buffer:text(), name_field(name), 1, true)
		if at then
			local start = buffer:line_start(buffer:line_of(at - 1))
			view:set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
		end
		greed.echo(`saved as :{name}`)
	end,
})

return M

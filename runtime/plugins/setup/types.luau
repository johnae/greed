-- Type checking for your config: luau-lsp and luau-analyze learn what
-- `require("@greed")`, `require("@theme")` and the other plugins are from a
-- `.luaurc`. For a file called `init.luau` they look for it from the folder
-- above (an `init.luau` stands for its folder), and they won't follow
-- aliases through a link, so Greed keeps one beside your config folder
-- (`~/.config/.luaurc`) with an alias for its API and each plugin it comes
-- with, as absolute paths into the runtime of the Greed you run. It's
-- written again when the editor starts, and only ever over what Greed wrote
-- there last: one you write or change yourself stays yours.

local greed = require("@greed")

local M = {}

--- Greed's runtime folder, with its types and plugins.
function M.runtime(): string?
	local core = greed.plugin.dirs().core
	return core and string.match(core, "^(.*)/plugins/[^/]+$")
end

--- The `.luaurc` aliasing `@greed` and each plugin in `runtime`.
function M.luaurc(runtime: string): string
	local names = {}
	for _, entry in greed.fs.list(`{runtime}/plugins`) or {} do
		if entry.dir then
			table.insert(names, entry.name)
		end
	end
	table.sort(names)
	local aliases = { `\t\t"greed": "{runtime}/types/greed"` }
	for _, name in names do
		table.insert(aliases, `\t\t"{name}": "{runtime}/plugins/{name}"`)
	end
	return '{\n\t"aliases": {\n' .. table.concat(aliases, ",\n") .. "\n\t}\n}\n"
end

-- Where what Greed last wrote is kept, to tell its own file from yours.
local function written_path(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/config-luaurc`
end

--- Sets up type checking for the config in `dir` (yours by default).
--- Returns what it did, or nil when there was nothing to do or it can't.
function M.update(dir: string?): string?
	local config = dir or greed.fs.dirs().config
	local runtime = M.runtime()
	local parent = config and string.match(config, "^(.*)/[^/]+/*$")
	local written = written_path()
	if
		parent == nil
		or runtime == nil
		or written == nil
		or greed.fs.stat(config :: string) == nil
	then
		return nil
	end
	local path = `{parent}/.luaurc`
	local existing = greed.fs.read(path)
	if existing and existing ~= greed.fs.read(written) then
		return nil
	end
	local wanted = M.luaurc(runtime)
	if existing == wanted then
		return nil
	end
	greed.fs.write(path, wanted)
	greed.fs.write(written, wanted)
	return `wrote {path} for type checking your config`
end

-- Once the plugins have loaded, so a session started by another Greed
-- points at its runtime.
greed.on("editor.started", function()
	pcall(M.update, nil)
end)

greed.command({
	name = "config-types",
	doc = "Set up type checking for your config: a .luaurc beside it that knows @greed and the plugins",
	run = function()
		greed.echo(M.update() or "your config's .luaurc is up to date, or one of your own is there")
	end,
})

return M

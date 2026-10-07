-- Greed's command line commands that are only Luau: `greed ls`, `greed new`,
-- `greed bring` and `greed reference`. Plugins add their own the same way:
--
--     greed.cli({
--         name = "hello",
--         doc = "Say hello",
--         usage = "[NAME]",
--         run = function(args)
--             return `hello {args[1] or "there"}`
--         end,
--     })
--
-- `greed hello world` then prints "hello world".

local greed = require("@greed")

local M = {}

greed.cli({
	name = "ls",
	doc = "List the running sessions and their projects",
	run = function()
		local lines = {}
		for _, session in greed.session.list() do
			table.insert(lines, string.format("%-20s %s", session.name, session.root or ""))
		end
		return table.concat(lines, "\n")
	end,
})

local MANIFEST = [[
name = "NAME"
# What it uses beyond the editor, e.g. ["proc", "fs.read"]; see the plugin docs.
capabilities = []
]]

local INIT = [[
-- NAME: say what this plugin does here.
--
-- Run `greed test .` in this directory to run its tests. To use it, put this
-- directory in the `plugins` directory next to your config
-- (~/.config/greed/plugins/NAME).

local greed = require("@greed")

greed.command({
	name = "NAME-greet",
	doc = "Insert a greeting at each cursor",
	run = function(ctx)
		ctx.buffer:edit(function(e)
			for _, range in ctx.view:selection().ranges do
				e:insert(range.head, "hello")
			end
		end)
	end,
})

-- Bind it to keys like this:
-- greed.keymap.bind({ layer = "leader" }, { x = "NAME-greet" })

return {}
]]

local TEST = [[
local test = require("@greed/test")

test("greet inserts a greeting", function(t)
	t:buffer("|!")
	t:run("NAME-greet")
	t:expect("hello|!")
end)
]]

local LUAURC = [[
{
	"languageMode": "strict",
	"aliases": {
		"greed": "./.greed-types/greed"
	}
}
]]

--- Makes the plugin `name` in `here`, with a test, and sets up type checking
--- there: a `.luaurc` aliasing `@greed` to a `.greed-types` link to Greed's
--- types. They live above the plugin because luau-analyze looks for an
--- `init.luau`'s config from its folder's parent. Returns what it did.
function M.new(here: string, name: string?): { string }
	if name == nil or not string.match(name, "^[%w_-]+$") then
		error("give the plugin a name: letters, digits, - and _", 0)
	end
	local dir = `{here}/{name}`
	if greed.fs.stat(dir) then
		error(`{name} already exists`, 0)
	end
	local files: { [string]: string } =
		{ ["plugin.toml"] = MANIFEST, ["init.luau"] = INIT, ["test/greet.luau"] = TEST }
	for file, text in files do
		local ok, err = greed.fs.write(`{dir}/{file}`, (string.gsub(text, "NAME", name)))
		if not ok then
			error(err, 0)
		end
	end
	local done = { `created {name}/: plugin.toml, init.luau, test/greet.luau` }
	local core = greed.plugin.dirs().core
	local runtime = core and string.match(core, "^(.*)/plugins/[^/]+$")
	if runtime and greed.fs.stat(here .. "/.greed-types") == nil then
		greed.process.run({ "ln", "-s", runtime .. "/types", here .. "/.greed-types" })
		table.insert(done, "linked .greed-types to Greed's type definitions")
	end
	local config = greed.fs.read(here .. "/.luaurc")
	if config == nil then
		greed.fs.write(here .. "/.luaurc", LUAURC)
		table.insert(done, "created .luaurc for type checking")
	elseif not string.find(config, '"greed"', 1, true) then
		table.insert(done, 'note: add "greed": "./.greed-types/greed" to the aliases in .luaurc')
	end
	table.insert(done, `run \`greed test {name}\` to try it`)
	return done
end

greed.cli({
	name = "new",
	doc = "Make a plugin to start from, with a test and type checking set up",
	usage = "NAME",
	run = function(args)
		return table.concat(M.new(greed.fs.cwd(), args[1]), "\n")
	end,
})

-- The far end's own plugins, one folder per line: its config's and its
-- data folder's.
local REMOTE_PLUGINS = [[
for d in "${XDG_CONFIG_HOME:-$HOME/.config}/greed/plugins" "${XDG_DATA_HOME:-$HOME/.local/share}/greed/plugins"; do
	for p in "$d"/*/; do [ -f "$p/plugin.toml" ] && echo "${p%/}"; done
done
true
]]

-- Copies plugin $4 from folder $3 on machine $2 into folder $1.
local COPY = [[mkdir -p "$1" && ssh "$2" "tar -C '$3' -cf - '$4'" | tar -C "$1" -xf -]]

greed.cli({
	name = "bring",
	doc = "Copy a plugin made on another machine (in its config or data folder) into your config",
	usage = "HOST [PLUGIN]",
	run = function(args)
		local host, name = args[1], args[2]
		if host == nil then
			error("which machine? greed bring HOST [PLUGIN]", 0)
		end
		local config = greed.fs.dirs().config
		if config == nil then
			error("there's no config folder here", 0)
		end
		local listed, err = greed.process.run({ "ssh", host, REMOTE_PLUGINS })
		if listed == nil or listed.code ~= 0 then
			error(`can't reach {host}: {if listed then listed.stderr else err}`, 0)
		end
		local found = {}
		for path in string.gmatch(listed.stdout, "[^\n]+") do
			local plugin = string.match(path, "([^/]+)$")
			if name == nil or plugin == name then
				table.insert(found, path)
			end
		end
		if #found == 0 then
			if name then
				error(`{host} has no plugin called {name}`, 0)
			end
			return `{host} has no plugins of its own`
		end
		if name == nil then
			local lines = { `{host} has these; greed bring {host} PLUGIN copies one here:` }
			for _, path in found do
				table.insert(lines, "  " .. path)
			end
			return table.concat(lines, "\n")
		end
		local parent, plugin = string.match(found[1], "^(.*)/([^/]+)$")
		if parent == nil or plugin == nil or string.find(found[1], "'", 1, true) then
			error(`can't copy {found[1]}`, 0)
		end
		local target = `{config}/plugins`
		local done, failed =
			greed.process.run({ "sh", "-c", COPY, "sh", target, host, parent, plugin })
		if done == nil or done.code ~= 0 then
			error(`copying {plugin} failed: {if done then done.stderr else failed}`, 0)
		end
		return `copied {plugin} from {host} into {target}/{plugin}; Greed asks you to approve it when it next starts`
	end,
})

--- Reference pages from the running editor (see docs.luau).
M.docs = require("@self/docs")

greed.cli({
	name = "reference",
	doc = "Write reference pages for the loaded plugins, their commands, keys and options, and the Luau API, as Markdown",
	usage = "DIR",
	run = function(args)
		local dir = args[1]
		if dir == nil then
			error("usage: greed reference DIR", 0)
		end
		return `wrote {table.concat(M.docs.write(dir), ", ")} in {dir}`
	end,
})

return M

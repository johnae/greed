local test = require("@greed/test")
local greed = require("@greed")
local cli = require("@cli")

test("docs writes the plugins, options and API pages from the running editor", function(t)
	local dir = t:tempdir({})
	local written = cli.docs.write(dir)
	assert(table.concat(written, " ") == "api.md options.md plugins.md", table.concat(written, " "))
	local plugins = greed.fs.read(dir .. "/plugins.md") :: string
	-- Each plugin's top comment, and its commands with their keys.
	assert(string.find(plugins, "\n## core\n", 1, true), "core has a section")
	assert(
		string.find(plugins, "`g g` (helix)", 1, true)
			and string.find(plugins, "| Move to the start of the buffer", 1, true),
		"commands come with their keys"
	)
	-- Keys bound by role, after the leader, or for one style's role.
	assert(string.find(plugins, "`g d` (every style's command mode)", 1, true), "a role")
	assert(string.find(plugins, "`k` (after the leader)", 1, true), "the leader")
	greed.keymap.bind({ style = "vim", role = "command" }, { ["z z z"] = "goto-definition" })
	plugins = greed.fs.read(dir .. "/" .. cli.docs.write(dir)[3]) :: string
	assert(string.find(plugins, "`z z z` (vim's command mode)", 1, true), "one style's role")
	local options = greed.fs.read(dir .. "/options.md") :: string
	assert(string.find(options, "| `motion-hints` | `false` | core |", 1, true), options)
	local api = greed.fs.read(dir .. "/api.md") :: string
	-- The module first, its fields linking to the types they are.
	assert(string.find(api, "# Luau API", 1, true) == 1, "a title")
	local module, buffer =
		string.find(api, "## `Greed`", 1, true), string.find(api, "## `Buffer`", 1, true)
	assert(module and buffer and module < buffer, "the module comes first")
	assert(
		string.find(api, "lsp: Lsp\n```\n\nLanguage servers", 1, true)
			or string.find(api, "[`Lsp`](#lsp)", 1, true),
		"lsp links to its type"
	)
	assert(
		string.find(
			api,
			"### `line_of`\n\n```luau\nline_of: (self: Buffer, pos: number) -> number\n```\n\nThe line `pos` is on.",
			1,
			true
		),
		"a method with its doc"
	)
end)

test("a plugin's top comment keeps its key lists and code as code", function()
	local page = cli.docs.plugins()
	assert(string.find(page, "```luau\n    greed.cli({", 1, true), "code examples stay code")
end)

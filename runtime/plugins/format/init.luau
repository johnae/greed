-- Formatting: `:format`, and on every save unless `format-on-save` is off.
-- A language's formatter program (see the languages plugin) is used when
-- it's installed; otherwise the language server is asked. Only what changed
-- is replaced, so the cursor and selections stay where they were.
--
-- To stop formatting on save:
--
--     require("@greed").option.set("format-on-save", false)

local greed = require("@greed")
local core = require("@core")
local M = require("@self/formatter")

greed.option.define({
	name = "format-on-save",
	doc = "Format files when they're saved",
	default = true,
})

greed.command({
	name = "format",
	doc = "Format the buffer with its language's formatter or language server",
	run = function(ctx)
		local formatted, err = M.format(ctx.buffer)
		if err then
			error(err, 0)
		elseif not formatted then
			greed.echo("nothing to format this with")
		end
	end,
})

-- Formatting on save runs the project's formatter and its config, which
-- can be code (prettier's .prettierrc.js): only in a project you trusted.
-- `:format` you run yourself.
core.file.before_save("format", function(buffer)
	local path = buffer:path()
	if
		greed.option.get("format-on-save") == true and (path == nil or core.project.trusts(path))
	then
		local _, err = M.format(buffer)
		if err then
			error(err, 0)
		end
	end
end)

-- Helix formats on =; this formats the whole buffer.
greed.keymap.bind({ style = "helix", role = "command" }, { ["="] = "format" })

return M

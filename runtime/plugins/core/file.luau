-- Saving and quitting.

local kern = require("@kern")

kern.command({
	name = "save",
	doc = "Write the buffer to its file",
	run = function(ctx)
		ctx.buffer:save()
		kern.echo("wrote " .. (ctx.buffer:path() or "?"))
	end,
})

kern.command({
	name = "quit",
	doc = "Exit the editor",
	run = function()
		kern.quit()
	end,
})

return {}

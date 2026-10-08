-- :secret-set NAME keeps a secret, like an API key, where plugins that
-- declare it can ask for it with greed.secrets.get: the system keyring, or
-- Greed's own secrets file where there is none. What you type shows as dots.

local greed = require("@greed")
local prompt = require("./prompt")

greed.command({
	name = "secret-set",
	doc = "Keep a secret, like an API key, in the system keyring (or Greed's secrets file)",
	args = { { name = "name", doc = "e.g. anthropic" } },
	run = function(ctx)
		local name = ctx.args[1] or prompt.ask("Name of the secret, e.g. anthropic")
		if name == nil or name == "" then
			return
		end
		local value = prompt.ask(
			`API key or other secret for {name}, kept in the system keyring (or Greed's secrets file)`,
			nil,
			{ secret = true }
		)
		if value == nil or value == "" then
			return
		end
		local where, err = greed.secrets.set(name, value)
		greed.echo(if where then `kept {name} in {where}` else `can't keep {name}: {err}`)
	end,
})

return {}

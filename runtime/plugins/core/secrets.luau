-- :secret-set NAME keeps a secret, like an API key, where plugins that
-- declare it can ask for it with kern.secrets.get: the system keyring, or
-- Kern's own secrets file where there is none. What you type shows as dots.

local kern = require("@kern")
local prompt = require("./prompt")

kern.command({
	name = "secret-set",
	doc = "Keep a secret, like an API key, in the system keyring (or Kern's secrets file)",
	args = { { name = "name", doc = "e.g. anthropic" } },
	run = function(ctx)
		local name = ctx.args[1] or prompt.ask("Secret's name")
		if name == nil or name == "" then
			return
		end
		local value = prompt.ask(`Value of {name}`, nil, { secret = true })
		if value == nil or value == "" then
			return
		end
		local where, err = kern.secrets.set(name, value)
		kern.echo(if where then `kept {name} in {where}` else `can't keep {name}: {err}`)
	end,
})

return {}

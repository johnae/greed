-- Acting for one of your accounts: picking it, and asking its service.

local greed = require("@greed")
local picker = require("@picker")
local backend = require("./backend")

local M = {}

--- The accounts signed in, by "service id", sorted; with `can` only those
--- whose service can do it (as `hello` says: "encryption"...).
function M.keys(can: string?): { string }
	local out = {}
	for key, account in backend.accounts do
		local offered = backend.can[account.service]
		if can == nil or (offered and offered[can]) then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

--- Runs `f` in a coroutine with the one of `keys`, or the one picked;
--- with none, says `none`.
function M.with_account(keys: { string }, none: string, f: (key: string) -> ())
	if #keys == 0 then
		greed.echo(none)
		return
	elseif #keys == 1 then
		greed.spawn(f, keys[1])
		return
	end
	local items = {}
	for _, key in keys do
		table.insert(items, { label = key, value = key })
	end
	picker.pick("Which account", items, function(chosen)
		greed.spawn(f, chosen.value)
	end)
end

--- Asks account `key`'s service `method`, with `extra`.
function M.ask(key: string, method: string, extra: { [string]: any }?): (any, string?)
	local service, id = backend.split(key)
	local params: { [string]: any } = { account = id }
	local more: { [string]: any } = extra or {}
	for name, value in more do
		params[name] = value
	end
	return backend.ask(service, method, params)
end

return M

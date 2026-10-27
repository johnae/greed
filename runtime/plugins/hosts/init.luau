-- Connecting to another machine from inside Greed: `space C` (`:connect`)
-- lists the hosts you connected to lately and those in ~/.ssh/config, and
-- going to one shows its session here, as `greed ssh HOST` would, starting
-- one there if none is running. Typing a host that isn't listed connects
-- to it too.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

local M = {}

-- How many hosts the recent list keeps.
local RECENT = 20

-- The file the recent hosts are kept in, newest first.
local function recent_file(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/recent-hosts`
end

--- The hosts connected to lately, newest first.
function M.recent(): { string }
	local file = recent_file()
	local text = file and greed.fs.read(file) or ""
	local hosts = {}
	for _, line in string.split(text, "\n") do
		if line ~= "" then
			table.insert(hosts, line)
		end
	end
	return hosts
end

-- Puts `host` first in the recent list.
local function remember(host: string)
	local file = recent_file()
	if file == nil then
		return
	end
	local hosts = { host }
	for _, other in M.recent() do
		if other ~= host and #hosts < RECENT then
			table.insert(hosts, other)
		end
	end
	greed.fs.write(file, table.concat(hosts, "\n") .. "\n")
end

--- The host names in an ssh config's `Host` lines, leaving out patterns
--- (`*`, `?`, `!`), in the order they come.
function M.parse_ssh_config(text: string): { string }
	local hosts = {}
	for _, line in string.split(text, "\n") do
		local names = string.match(line, "^%s*[Hh][Oo][Ss][Tt][%s=]+(.-)%s*$")
		if names then
			for name in string.gmatch(names, "%S+") do
				if not string.find(name, "[%*%?!]") and not table.find(hosts, name) then
					table.insert(hosts, name)
				end
			end
		end
	end
	return hosts
end

--- The ssh config to read hosts from, when not ~/.ssh/config.
M.ssh_config = nil :: string?

--- The hosts in ~/.ssh/config (or `M.ssh_config`).
function M.configured(): { string }
	local home = greed.fs.dirs().home
	local path = M.ssh_config or (home and `{home}/.ssh/config`)
	local text = path and greed.fs.read(path)
	return if text then M.parse_ssh_config(text) else {}
end

--- Shows the session on `host` here, remembering it for next time.
function M.connect(host: string)
	remember(host)
	greed.session.switch({ host = host })
end

--- Whether this session is on another machine than you, as one `greed ssh`
--- started is.
function M.away(): boolean
	return greed.session.remote()
end

-- The value of the picker's item for your own machine, apart from host names.
local HOME = {}

-- Every host the picker lists: your own machine first when this session
-- is on another, then recent ones, then the configured.
local function items(): { picker.Item }
	local list: { picker.Item } = {}
	if M.away() then
		table.insert(list, { label = "home", detail = "the machine you are at", value = HOME })
	end
	local listed: { [string]: boolean } = {}
	local function add(host: string, note: string)
		if not listed[host] then
			listed[host] = true
			table.insert(list, { label = host, detail = note, value = host })
		end
	end
	for _, host in M.recent() do
		add(host, "recent")
	end
	for _, host in M.configured() do
		add(host, "~/.ssh/config")
	end
	return list
end

greed.command({
	name = "connect",
	doc = "Show a session on another machine here, as greed ssh does: pick a host, or type one",
	args = { { name = "host", doc = "The host, as ssh knows it" } },
	run = function(ctx)
		local host = ctx.args[1]
		if host then
			M.connect(host)
			return
		end
		picker.pick("Connect to", items(), function(item)
			if item.value == HOME then
				greed.session.switch({ home = true })
			else
				M.connect(item.value)
			end
		end, {
			fallback = function(query)
				local typed = string.match(query, "^%s*(%S+)%s*$")
				if typed then
					M.connect(typed)
				end
			end,
		})
	end,
})

greed.keymap.bind({ layer = "leader" }, { C = "connect" })
core.menus.add("File", "Connect to Host…", "connect")

return M

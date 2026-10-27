local test = require("@greed/test")
local hosts = require("@hosts")

test("an ssh config's hosts are its Host names, leaving out patterns", function()
	local found = hosts.parse_ssh_config(table.concat({
		"Host build-box",
		"  HostName 10.0.0.5",
		"host gpu1 gpu2",
		"Host *.internal !secret bastion",
		"Host=web",
		"Host *",
		"  User me",
	}, "\n"))
	assert(table.concat(found, " ") == "build-box gpu1 gpu2 bastion web", table.concat(found, " "))
end)

test("the picker lists recent hosts first, then the configured ones, each once", function(t)
	local dir = t:tempdir({ ["config"] = "Host build-box\nHost gpu1\n" })
	hosts.ssh_config = `{dir}/config`
	t:buffer("|")
	t:run("connect", { "gpu1" })
	t:run("connect")
	local shown = table.concat(t:floats(), "\n")
	local recent = string.find(shown, "gpu1  +recent")
	local configured = string.find(shown, "build%-box  +~/%.ssh/config")
	assert(recent and configured and recent < configured, shown)
	assert(not string.find(shown, "gpu1  +~/%.ssh/config"), "listed once: " .. shown)
	hosts.ssh_config = nil
end)

test("connecting sends the client to the host and puts it first in the recent list", function(t)
	t:buffer("|")
	t:run("connect", { "one" })
	local to = t:switched()
	assert(to and to.host == "one" and to.session == nil, "switched to one")
	t:run("connect", { "two" })
	t:run("connect", { "one" })
	local recent = hosts.recent()
	assert(recent[1] == "one" and recent[2] == "two" and #recent == 2, table.concat(recent, " "))
end)

test("a host typed in the picker that isn't listed is connected to", function(t)
	hosts.ssh_config = `{t:tempdir({ ["config"] = "" })}/config`
	t:buffer("|")
	t:run("connect")
	t:type("lab-7")
	t:keys("enter")
	local to = t:switched()
	assert(to and to.host == "lab-7", "switched to the typed host")
	hosts.ssh_config = nil
end)

test("on another machine the picker offers home first, which sends the client home", function(t)
	hosts.ssh_config = `{t:tempdir({ ["config"] = "Host build-box\n" })}/config`
	t:buffer("|")
	t:run("connect")
	assert(not string.find(table.concat(t:floats(), "\n"), "home", 1, true), "not here")
	t:keys("esc")
	local away = hosts.away
	hosts.away = function()
		return true
	end
	t:run("connect")
	local shown = table.concat(t:floats(), "\n")
	local home = string.find(shown, "home  +the machine you are at")
	local host = string.find(shown, "build-box", 1, true)
	hosts.away = away
	assert(home and host and home < host, shown)
	t:keys("enter")
	local to = t:switched()
	assert(to and to.home and to.host == nil, "home")
	hosts.ssh_config = nil
end)

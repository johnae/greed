-- Asking before a program uses your ssh keys. A session `greed ssh` started
-- reaches your ssh agent through the client you attached with; before a
-- program there signs with one of your keys, you're asked on that client,
-- as `ssh-agent-confirm` says: never, the first time since the client
-- attached, or every time.

local greed = require("@greed")

greed.option.define({
	name = "ssh-agent-confirm",
	needs = "ssh-agent",
	default = "first",
	choices = { "never", "first", "always" },
	doc = "When to ask before a program in a session from greed ssh signs with your ssh key: never, first (once each time you attach) or always",
})

-- The clients you allowed since they attached, for "first".
local allowed: { [number]: boolean } = {}
-- The requests waiting behind the question on each client's screen,
-- oldest first; a client with a question showing has a list.
local waiting: { [number]: { greed.Signal } } = {}

-- Waits until no other question shows on `client`.
local function take_turn(client: number)
	local queue = waiting[client]
	if queue == nil then
		waiting[client] = {}
		return
	end
	local turn = greed.signal()
	table.insert(queue, turn)
	turn:wait()
end

-- Lets the next request waiting on `client` ask.
local function pass_turn(client: number)
	local queue = waiting[client]
	if queue == nil then
		return
	end
	local next_turn = table.remove(queue, 1)
	if next_turn then
		next_turn:send(true)
	else
		waiting[client] = nil
	end
end

-- Asks you whether a program may sign with your key from `host`; only a
-- key you press answers, never keys a plugin feeds.
local function ask(host: string?, until_detach: boolean): boolean
	local here = greed.hostname() or "the other machine"
	local yours = if host then ` on {host}` else ""
	local scope = if until_detach then " (until you detach)" else ""
	greed.echo(`a program on {here} asks to sign with your ssh key{yours}: allow{scope}? y/n`)
	local yes = greed.next_key() == "y"
	greed.echo(if yes then "" else "refused the ssh key")
	return yes
end

greed.on("ssh_agent.use", function(event: greed.SshAgentUse)
	local confirm = greed.option.get("ssh-agent-confirm")
	local first = confirm == "first"
	if confirm == "never" or (first and allowed[event.client]) then
		greed.ssh_agent.answer(event.id, true)
		return
	end
	take_turn(event.client)
	-- You may have allowed one waiting before this.
	local yes = if first and allowed[event.client] then true else ask(event.host, first)
	if yes and first then
		allowed[event.client] = true
	end
	greed.ssh_agent.answer(event.id, yes)
	pass_turn(event.client)
end)

greed.on("client.detached", function(event: greed.ClientDetached)
	allowed[event.client] = nil
	waiting[event.client] = nil
end)

return {}

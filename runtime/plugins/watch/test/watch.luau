local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")
local chat = require("@chat")
local watch = require("@watch")
local models: any = require("@models")

local backend = chat.backend

-- Stands in for the model: each turn calls the next of `calls` (a tool's
-- name and input), then ends.
local function script(calls: { { any } })
	local at = 0
	models.check = function(): string?
		return nil
	end
	models.turn = function(_role, _request): (any, string?, boolean?)
		at += 1
		local call = calls[at]
		if call == nil then
			return { text = "", calls = {}, stop = "done" }, nil
		end
		return {
			text = "",
			calls = { { id = `c{at}`, name = call[1], input = call[2] } },
			stop = "tools",
		},
			nil
	end
end

-- A Mattermost account with the rooms Help and Infra, which keeps what's
-- sent in `sent`; returns what tells of new messages.
local function service(sent: { any }): (messages: { any }) -> ()
	backend.reset()
	local notify = backend.use("mattermost", {
		rooms = function(): any
			return {}
		end,
		send = function(params: any)
			table.insert(sent, params)
			return nil
		end,
	})
	notify(
		"account.changed",
		{ id = "anna", server = "https://mm.x", name = "Anna", state = { state = "ready" } }
	)
	return function(messages: { any })
		notify("messages", { account = "anna", messages = messages })
	end
end

local function said(room: string, name: string, event: string, text: string, mine: boolean?): any
	return {
		room = room,
		room_name = name,
		event = event,
		sender = { id = if mine then "anna" else "bea", name = if mine then "Anna" else "Bea" },
		at = os.time() * 1000,
		text = text,
		mine = mine == true,
		direct = false,
	}
end

-- The last entries of watcher `name`'s log, as "what: text".
local function logged(name: string): { string }
	local out = {}
	for _, entry in watch.log(name) do
		table.insert(out, `{entry.what}: {entry.text}`)
	end
	return out
end

local function has(lines: { string }, wanted: string): boolean
	for _, line in lines do
		if string.find(line, wanted, 1, true) then
			return true
		end
	end
	return false
end

local count = 0
-- A watcher of Help and Infra with a fresh name, gathering for no time.
local function watcher(fields: { [string]: any }?): string
	count += 1
	local name = `w{count}`
	local spec: any = {
		name = name,
		prompt = "Escalate outages.",
		watch = { chat = { rooms = { "help", "#Infra" } } },
		gather = 0,
	}
	local given: { [string]: any } = fields or {}
	for key, value in given do
		spec[key] = value
	end
	watch.add(spec)
	return name
end

watch.here = function(): boolean
	return true
end

test("quiet hours, past midnight too", function()
	-- Today's local midnight, and times from it.
	local now = os.time()
	local clock = os.date("*t", now) :: any
	local midnight = now - clock.hour * 3600 - clock.min * 60 - clock.sec
	local function at(hour: number, minute: number): number
		return midnight + hour * 3600 + minute * 60
	end
	assert(watch.in_quiet("22:00-07:00", at(23, 30)))
	assert(watch.in_quiet("22:00-07:00", at(6, 59)))
	assert(not watch.in_quiet("22:00-07:00", at(7, 0)))
	assert(watch.in_quiet("12:00-13:00", at(12, 15)))
	assert(not watch.in_quiet("12:00-13:00", at(13, 15)))
	assert(not watch.in_quiet(nil, at(3, 0)) and not watch.in_quiet("whenever", at(3, 0)))
end)

test("a new watcher is in quarantine; it's turned on, off, paused and resumed", function()
	local name = watcher()
	assert(watch.state(name) == "quarantine", watch.state(name))
	assert(watch.set(name, "on") and watch.state(name) == "on")
	assert(watch.pause(name, 60) and watch.state(name) == "paused")
	assert(watch.resume(name) and watch.state(name) == "on", "back as it was")
	assert(watch.set(name, "off") and watch.state(name) == "off")
	assert(not watch.set(name, "sideways"), "only on, off or quarantine")
	assert(not watch.pause("nobody"), "no such watcher")
	local free = watcher({ quarantine = false })
	assert(watch.state(free) == "on", "out of quarantine when the config says")
end)

test("a signature is the config's until changed, and can be turned off", function()
	local name = watcher({ sign = "(assistant)" })
	assert(watch.signature(name) == "(assistant)")
	watch.sign(name, "— bot")
	assert(watch.signature(name) == "— bot")
	watch.sign(name, false)
	assert(watch.signature(name) == nil)
end)

test("a message in a watched room wakes it; in quarantine an escalation is only logged", function(t)
	local tell = service({})
	local name = watcher()
	script({
		{
			"watch_escalate",
			{ text = "The database is down", account = "mattermost anna", room = "r-infra" },
		},
		{ "watch_done", { summary = "escalated the outage" } },
	})
	tell({
		said("r-other", "Other", "e0", "not watched"),
		said("r-infra", "Infra", "e1", "the database is down"),
		said("r-help", "Help", "e2", "mine", true),
	})
	t:wait_for(function(): boolean
		return has(logged(name), "done:")
	end)
	local lines = logged(name)
	assert(has(lines, "woke: 1 new message"), table.concat(lines, "\n"))
	assert(has(lines, "would escalate: Infra: The database is down"), table.concat(lines, "\n"))
	assert(not has(lines, "escalated:"), "nothing shown in quarantine")
end)

test("released, it drafts; a draft is sent only when you send it", function(t)
	local sent = {}
	local tell = service(sent)
	local name = watcher({ quarantine = false })
	script({
		{
			"watch_draft",
			{
				account = "mattermost anna",
				room = "r-help",
				text = "Try restarting it",
				reply_to = "e3",
			},
		},
		{ "watch_draft", { account = "mattermost anna", room = "r-elsewhere", text = "sneaky" } },
	})
	tell({ said("r-help", "Help", "e3", "how do I fix the VPN?") })
	t:wait_for(function(): boolean
		return has(logged(name), "drafted:")
	end)
	t:wait(50)
	local mine: { watch.Draft } = {}
	for _, d in watch.drafts() do
		if d.watcher == name then
			table.insert(mine, d)
		end
	end
	assert(
		#mine == 1 and mine[1].text == "Try restarting it" and mine[1].room_name == "Help",
		"one draft, in a room it woke for"
	)
	assert(#sent == 0, "nothing sent yet")
	local done = false
	greed.spawn(function()
		assert(watch.send_draft(mine[1].id))
		done = true
	end)
	t:wait_for(function(): boolean
		return done
	end)
	assert(
		#sent == 1 and sent[1].text == "Try restarting it" and sent[1].reply_to == "e3",
		greed.json.encode(sent)
	)
	assert(has(logged(name), "you sent: Help: Try restarting it"))
end)

test("it replies on its own only where allowed, signed, and within its budget", function(t)
	local sent = {}
	local tell = service(sent)
	local name = watcher({
		quarantine = false,
		sign = "(assistant)",
		may = { reply = "auto", auto_in = { "help" } },
		budget = { replies_per_hour = 1 },
	})
	script({
		{
			"watch_reply",
			{ account = "mattermost anna", room = "r-help", text = "The runbook is in Hoard" },
		},
		{
			"watch_reply",
			{ account = "mattermost anna", room = "r-infra", text = "not allowed here" },
		},
		{ "watch_reply", { account = "mattermost anna", room = "r-help", text = "over budget" } },
		{ "watch_done", { summary = "answered" } },
	})
	tell({
		said("r-help", "Help", "e4", "where's the runbook?"),
		said("r-infra", "Infra", "e5", "anyone?"),
	})
	t:wait_for(function(): boolean
		return has(logged(name), "done:")
	end)
	assert(#sent == 1, greed.json.encode(sent))
	assert(sent[1].text == "The runbook is in Hoard (assistant)", sent[1].text)
	local lines = logged(name)
	assert(
		has(lines, "replied: Help: The runbook is in Hoard (assistant)"),
		table.concat(lines, "\n")
	)
	assert(has(lines, "over budget: Help: over budget"), table.concat(lines, "\n"))
end)

test("a paused watcher keeps what comes, an off one drops it", function(t)
	local tell = service({})
	local name = watcher({ quarantine = false })
	script({})
	watch.pause(name, 3600)
	tell({ said("r-help", "Help", "e6", "hello?") })
	t:wait(50)
	assert(not has(logged(name), "woke:"), "paused, it doesn't wake")
	watch.resume(name)
	t:wait_for(function(): boolean
		return has(logged(name), "woke: 1 new message")
	end)
	watch.set(name, "off")
	tell({ said("r-help", "Help", "e7", "still there?") })
	t:wait(50)
	local woke = 0
	for _, line in logged(name) do
		woke += if string.find(line, "^woke:") then 1 else 0
	end
	assert(woke == 1, "off, it doesn't wake: " .. table.concat(logged(name), "\n"))
end)

test("other agents can't use a watcher's tools", function()
	for _, tool in agent.tools() do
		if tool.name == "watch_escalate" then
			local ok, err = pcall(tool.run, { text = "hi" }, agent.caller())
			assert(
				not ok and string.find(tostring(err), "only a watcher's agent", 1, true),
				tostring(err)
			)
			return
		end
	end
	error("no watch_escalate")
end)

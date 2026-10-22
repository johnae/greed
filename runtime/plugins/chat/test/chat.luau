local test = require("@greed/test")
local greed = require("@greed")
local chat = require("@chat")

local backend = chat.backend

-- A Matrix service with one account and two rooms; what it was asked to
-- send goes in `sent`. Gives the way to send its notifications.
local function fake(sent: { any }?): (method: string, params: any) -> ()
	backend.reset()
	local items = {
		{
			id = "d",
			kind = "day",
			at = 1792660000000,
			sender = { id = "", name = "" },
			text = "",
			replies = 0,
			reactions = {},
			edited = false,
			mine = false,
		},
		{
			id = "1",
			event = "$1",
			kind = "message",
			at = 1792660000000,
			sender = { id = "@bea:x", name = "Bea" },
			text = "lunch at noon?",
			replies = 0,
			reactions = { { key = "👍", count = 2, mine = true } },
			edited = false,
			mine = false,
		},
	}
	local notify = backend.use("matrix", {
		rooms = function(): any
			return {
				{
					id = "!quiet:x",
					account = "@anna:x",
					name = "Quiet",
					kind = "room",
					unread = 0,
					mentions = 0,
					favourite = false,
					muted = false,
					encrypted = false,
					active = 1,
				},
				{
					id = "!plans:x",
					account = "@anna:x",
					name = "Plans",
					kind = "room",
					unread = 3,
					mentions = 1,
					favourite = false,
					muted = false,
					encrypted = true,
					active = 2,
				},
				{
					id = "!crew:x",
					account = "@anna:x",
					name = "Crew",
					kind = "space",
					unread = 0,
					mentions = 0,
					favourite = false,
					muted = false,
					encrypted = false,
					active = 0,
				},
			}
		end,
		timeline = function(): any
			return { items = items }
		end,
		send = function(params: any)
			if sent then
				table.insert(sent, params)
			end
			return nil
		end,
		["timeline.close"] = function()
			return nil
		end,
	})
	notify("account.changed", {
		id = "@anna:x",
		server = "https://x",
		name = "Anna",
		state = { state = "ready" },
	})
	return notify
end

test("the list shows each account's rooms, those with mentions and unread first", function(t)
	fake()
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, "Anna", 1, true), text)
	local plans = string.find(text, "Plans", 1, true)
	local quiet = string.find(text, "Quiet", 1, true)
	assert(plans and quiet and plans < quiet, text)
	assert(string.find(text, "@1", 1, true), "its mentions: " .. text)
	assert(not string.find(text, "Crew", 1, true), "spaces aren't rooms to open")
end)

test("enter opens a room: its messages, kept up to date, and a box that sends", function(t)
	local sent = {}
	local notify = fake(sent)
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	assert(greed.view():buffer():kind() == "chat")
	t:keys("enter")
	t:wait(50)
	local room = greed.view():buffer()
	assert(room:kind() == "chat-room", room:kind())
	local text = room:text()
	assert(string.find(text, "Bea", 1, true), text)
	assert(string.find(text, "lunch at noon?", 1, true), text)
	assert(string.find(text, "👍 2", 1, true), "its reactions: " .. text)

	notify("timeline.changed", {
		account = "@anna:x",
		room = "!plans:x",
		changes = {
			{
				op = "insert",
				at = 2,
				item = {
					id = "2",
					event = "$2",
					kind = "message",
					at = 1792660060000,
					sender = { id = "@bea:x", name = "Bea" },
					text = "or one?",
					replies = 0,
					reactions = {},
					edited = false,
					mine = false,
				},
			},
		},
	})
	t:wait(50)
	text = room:text()
	assert(string.find(text, "or one?", 1, true), "a new message shows: " .. text)

	t:keys("i")
	t:type("noon works")
	t:keys("enter")
	t:wait(50)
	assert(#sent == 1 and sent[1].text == "noon works", "it was sent")
	assert(sent[1].room == "!plans:x" and sent[1].account == "@anna:x")
	assert(not string.find(room:text(), "noon works", 1, true), "the box is empty again")
end)

test("changes apply as the protocol says", function()
	local items: { any } = { { id = "a" }, { id = "b" }, { id = "c" } }
	chat.apply(items, {
		{ op = "set", at = 1, item = { id = "B" } },
		{ op = "remove", at = 0 },
		{ op = "insert", at = 0, item = { id = "z" } },
		{ op = "truncate", len = 2 },
	})
	assert(#items == 2 and items[1].id == "z" and items[2].id == "B", greed.json.encode(items))
	chat.apply(items, { { op = "reset", items = { { id = "x" } } } })
	assert(#items == 1 and items[1].id == "x")
	chat.apply(items, { { op = "clear" } })
	assert(#items == 0)
end)

test("signing in with a password asks for each field, then keeps the account", function(t)
	backend.reset()
	local answered: any = nil
	backend.use("matrix", {
		["login.methods"] = function()
			return { { kind = "password" } }
		end,
		["login.start"] = function()
			return {
				login = "l1",
				step = {
					step = "ask",
					fields = {
						{ name = "user", label = "Username", secret = false },
						{ name = "password", label = "Password", secret = true },
					},
				},
			}
		end,
		["login.answer"] = function(params: any)
			answered = params
			return {
				step = "done",
				account = { id = "@anna:x", server = "https://x", state = { state = "syncing" } },
				secret = "the tokens",
			}
		end,
	})
	t:buffer("|x")
	t:run("chat-login")
	t:keys("enter") -- matrix, the first
	t:type("x.org")
	t:keys("enter")
	t:keys("enter") -- password, the only way
	t:type("anna")
	t:keys("enter")
	t:type("pw")
	t:keys("enter")
	t:wait(100)
	assert(answered and answered.values.user == "anna" and answered.values.password == "pw")
	assert(backend.accounts["matrix @anna:x"], "the account is there")
	local kept
	greed.spawn(function()
		kept = greed.secrets.get("chat-matrix")
	end)
	t:wait(100)
	assert(kept and string.find(kept, "the tokens", 1, true), tostring(kept))
end)

test("the real services start, agree on the protocol, and answer", function(t)
	backend.reset()
	for _, service in backend.SERVICES do
		local program = backend.program(service)
		if not string.find(program, "/", 1, true) then
			-- Not built beside this greed; nothing to try.
			continue
		end
		local accounts, why
		greed.spawn(function()
			accounts, why = backend.ask(service, "accounts", {})
		end)
		t:wait_for(function(): boolean
			return accounts ~= nil or why ~= nil
		end, 5000)
		assert(accounts and #accounts == 0, `{service}: {why}`)
	end
	backend.reset()
end)

test("messages are Markdown; a quote or list that would run on gets a blank line", function(t)
	assert(chat.runs_on("plans:\n- tomatoes"))
	assert(chat.runs_on("> remember the gloves"))
	assert(chat.runs_on("1. first"))
	assert(not chat.runs_on("just **words**"))
	assert(not chat.runs_on("```\ncode\n```"), "closed code doesn't run on")
	fake()
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("enter")
	t:wait(50)
	local room = greed.view():buffer()
	assert(room:language() == "markdown", room:language())
end)

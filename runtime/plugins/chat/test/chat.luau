local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local chat = require("@chat")

local backend = chat.backend

-- A Matrix service with one account and two rooms; what it was asked to
-- send goes in `sent`. Gives the way to send its notifications.
-- What the fake service was asked, other than rooms: {method, params}.
local asked: { { method: string, params: any } } = {}

local function fake(sent: { any }?): (method: string, params: any) -> ()
	table.clear(asked)
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
		{
			id = "3",
			event = "$3",
			kind = "message",
			at = 1792660030000,
			sender = { id = "@anna:x", name = "Anna" },
			text = "noon is fine",
			replies = 2,
			reactions = {},
			edited = false,
			mine = true,
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
		timeline = function(params: any): any
			table.insert(asked, { method = "timeline", params = params })
			return { items = items }
		end,
		send = function(params: any)
			if sent then
				table.insert(sent, params)
			end
			return nil
		end,
		["react"] = function(params: any)
			table.insert(asked, { method = "react", params = params })
			return nil
		end,
		["edit"] = function(params: any)
			table.insert(asked, { method = "edit", params = params })
			return nil
		end,
		["redact"] = function(params: any)
			table.insert(asked, { method = "redact", params = params })
			return nil
		end,
		["read"] = function(params: any)
			table.insert(asked, { method = "read", params = params })
			return nil
		end,
		["typing"] = function(params: any)
			table.insert(asked, { method = "typing", params = params })
			return nil
		end,
		vote = function(params: any)
			table.insert(asked, { method = "vote", params = params })
			return nil
		end,
		preview = function(params: any): any
			table.insert(asked, { method = "preview", params = params })
			return { url = params.url, title = "Plots of land" }
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

test(
	"the list shows each account's rooms, those with mentions and unread first, then spaces",
	function(t)
		fake()
		t:buffer("|x")
		t:run("chat")
		t:wait(50)
		local text = greed.view():buffer():text()
		assert(string.find(text, "Anna", 1, true), text)
		local plans = string.find(text, "Plans", 1, true)
		local quiet = string.find(text, "Quiet", 1, true)
		assert(plans and quiet and plans < quiet, text)
		local crew = string.find(text, "◆  Crew", 1, true)
		assert(crew and crew > quiet, "spaces come after the rooms in none: " .. text)
	end
)

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

-- Opens the fake's Plans room, with the cursor on the message `event`.
local function on_message(t: any, event: string): greed.Buffer
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("enter")
	t:wait(50)
	local buffer = greed.view():buffer()
	local r = chat.rooms.of(buffer)
	assert(r, "a room is open")
	local line = r.view:line_of(function(value: any): boolean
		return value ~= nil and value.item.event == event
	end)
	assert(line, `no message {event}`)
	greed.view():set_cursor(buffer:line_start(line :: number))
	return buffer
end

-- The calls the fake service had of `method`.
local function calls(method: string): { any }
	local out = {}
	for _, call in asked do
		if call.method == method then
			table.insert(out, call.params)
		end
	end
	return out
end

test("a room is marked read as it opens, and says who's writing", function(t)
	local notify = fake()
	on_message(t, "$1")
	t:wait(50)
	assert(#calls("read") == 1 and calls("read")[1].room == "!plans:x", "marked read")
	notify("typing.changed", { account = "@anna:x", room = "!plans:x", who = { "Bea" } })
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, "Bea is writing…", 1, true), text)
	assert(string.find(text, "2 replies", 1, true), "how many replies a thread has: " .. text)
end)

test("alt-k reacts with an emoji picked", function(t)
	fake()
	on_message(t, "$1")
	t:keys("alt-k")
	t:keys("enter") -- 👍, the first
	t:wait(50)
	local reacted = calls("react")
	assert(
		#reacted == 1 and reacted[1].event == "$1" and reacted[1].key == "👍",
		greed.json.encode(asked)
	)
end)

test("alt-e puts your message in the box; enter sends the change", function(t)
	fake()
	local buffer = on_message(t, "$3")
	t:keys("alt-e")
	assert(string.find(buffer:text(), "changing your message", 1, true), buffer:text())
	t:keys("i")
	t:type(", or one")
	t:keys("enter")
	t:wait(50)
	local edits = calls("edit")
	assert(#edits == 1 and edits[1].event == "$3", greed.json.encode(asked))
	assert(edits[1].text == "noon is fine, or one", edits[1].text)
end)

test("alt-e on someone else's message changes nothing", function(t)
	fake()
	on_message(t, "$1")
	t:keys("alt-e")
	t:wait(50)
	local messages = t:messages()
	assert(string.find(messages[#messages], "only your own", 1, true), messages[#messages])
end)

test("alt-d deletes after asking; anything but y keeps it", function(t)
	fake()
	on_message(t, "$3")
	t:keys("alt-d")
	t:keys("n")
	t:wait(50)
	assert(#calls("redact") == 0, "kept")
	t:keys("alt-d")
	t:keys("y")
	t:wait(50)
	local deleted = calls("redact")
	assert(#deleted == 1 and deleted[1].event == "$3", greed.json.encode(asked))
end)

test("alt-t opens the thread; what's sent there goes in it; q goes back", function(t)
	local sent = {}
	fake(sent)
	local room = on_message(t, "$3")
	t:keys("alt-t")
	t:wait(50)
	local thread = greed.view():buffer()
	assert(thread:id() ~= room:id(), "the thread is a view of its own")
	local opened = calls("timeline")
	assert(opened[#opened].thread == "$3", greed.json.encode(opened))
	assert(string.find(thread:text(), "in the thread", 1, true), thread:text())
	t:keys("i")
	t:type("sure")
	t:keys("enter")
	t:wait(50)
	assert(
		#sent == 1 and sent[1].thread == "$3" and sent[1].text == "sure",
		greed.json.encode(sent)
	)
	-- Still writing after sending: esc stops, then q goes back.
	t:keys("esc")
	assert(
		greed.view():buffer():id() == thread:id(),
		"esc only stops writing: " .. greed.view():buffer():kind()
	)
	t:keys("q")
	assert(
		greed.view():buffer():id() == room:id(),
		greed.view():buffer():kind() .. " " .. greed.view():buffer():text()
	)
end)

test("enter on a file fetches and opens it; :chat-attach sends one", function(t)
	fake()
	local dir = t:tempdir({ ["notes.txt"] = "tomatoes by the fence\n", ["beds.txt"] = "beans\n" })
	backend.use("matrix", {
		timeline = function(): any
			return {
				items = {
					{
						id = "5",
						event = "$5",
						kind = "file",
						at = 1792660000000,
						sender = { id = "@bea:x", name = "Bea" },
						text = "notes.txt",
						replies = 0,
						reactions = {},
						edited = false,
						mine = false,
						media = {
							name = "notes.txt",
							mime = "text/plain",
							size = 22,
							thumbnail = false,
						},
					},
				},
			}
		end,
		rooms = function(): any
			return {
				{
					id = "!plans:x",
					account = "@anna:x",
					name = "Plans",
					kind = "room",
					unread = 0,
					mentions = 0,
					favourite = false,
					muted = false,
					encrypted = false,
					active = 2,
				},
			}
		end,
		["media.get"] = function(params: any): any
			table.insert(asked, { method = "media.get", params = params })
			return { path = dir .. "/notes.txt" }
		end,
		upload = function(params: any)
			-- What the service would send, read while it's there.
			params.text = greed.fs.read(params.path)
			table.insert(asked, { method = "upload", params = params })
			return nil
		end,
		read = function()
			return nil
		end,
	})
	-- Small pieces, so both files go in several.
	local piece = backend.PIECE
	backend.PIECE = 5
	local room = on_message(t, "$5")
	local text = room:text()
	assert(string.find(text, "📄 notes.txt", 1, true), text)
	assert(string.find(text, "22 B", 1, true), "its size: " .. text)
	t:keys("enter")
	t:wait(100)
	local fetched = calls("media.get")
	assert(#fetched == 1 and fetched[1].event == "$5", greed.json.encode(asked))
	local shown = greed.view():buffer()
	assert(
		string.find(shown:text(), "tomatoes by the fence", 1, true),
		"it opened: " .. shown:text()
	)

	greed.view():show(room)
	t:run("chat-attach", { dir .. "/beds.txt" })
	t:wait(50)
	local sent = calls("upload")
	-- It goes to the owner as data, and the service sends the owner's copy.
	assert(#sent == 1 and sent[1].text == "beans\n", greed.json.encode(asked))
	assert(string.find(sent[1].path, "-beds.txt$") ~= nil, sent[1].path)
	assert(greed.fs.stat(sent[1].path) == nil, "the copy goes once it's sent")
	backend.PIECE = piece
end)

test("a browser sign-in finishes with the link :chat-link hands over", function(t)
	backend.reset()
	local answered: any = nil
	backend.use("mattermost", {
		["login.methods"] = function(): any
			return { { kind = "browser", id = "openid", name = "Keycloak" } }
		end,
		["login.start"] = function(): any
			return {
				login = "l2",
				step = {
					step = "open",
					url = "https://mm.example.com/oauth/openid/login",
					paste = "the link",
				},
			}
		end,
		["login.answer"] = function(params: any): any
			answered = params
			return {
				step = "done",
				account = {
					id = "u1@mm.example.com",
					server = "https://mm.example.com",
					state = { state = "syncing" },
				},
				secret = "token",
			}
		end,
	})
	greed.option.set("link-opener", "true")
	t:buffer("|x")
	t:run("chat-login")
	t:type("mattermost")
	t:keys("enter")
	t:type("mm.example.com")
	t:keys("enter")
	t:keys("enter") -- in the browser
	t:wait(50)
	local link = "mattermost://mm.example.com/login/desktop?client_token=a&server_token=b"
	t:run("chat-link", { link })
	t:wait(100)
	assert(answered and answered.values.link == link, greed.json.encode(answered))
	assert(backend.accounts["mattermost u1@mm.example.com"], "signed in")
	t:keys("esc") -- the paste prompt, not needed now
end)

-- A Matrix service that encrypts, with one account whose device isn't
-- verified; what it's asked goes in `asked`.
local function encrypting(): (method: string, params: any) -> ()
	table.clear(asked)
	backend.reset()
	local function record(method: string): (params: any) -> any
		return function(params: any): any
			table.insert(asked, { method = method, params = params })
			return nil
		end
	end
	local notify = backend.use("matrix", {
		rooms = function(): any
			return {}
		end,
		["encryption.state"] = function(): any
			return { recovery = "incomplete", verified = false }
		end,
		["encryption.recover"] = record("encryption.recover"),
		["verify.accept"] = record("verify.accept"),
		["verify.confirm"] = record("verify.confirm"),
		["verify.cancel"] = record("verify.cancel"),
	}, { "encryption" })
	notify("account.changed", {
		id = "@anna:x",
		server = "https://x",
		name = "Anna",
		state = { state = "ready" },
	})
	return notify
end

test("an unverified device says so; :chat-recover takes the key out of sight", function(t)
	encrypting()
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, "isn't verified", 1, true), text)
	t:keys("esc")
	t:run("chat-recover")
	t:type("EsTc 1234 abcd")
	t:keys("enter")
	t:wait(50)
	local recovered = calls("encryption.recover")
	assert(#recovered == 1 and recovered[1].key == "EsTc 1234 abcd", greed.json.encode(asked))
end)

test("another device asking is asked about; the emoji are shown to compare, once", function(t)
	local notify = encrypting()
	t:buffer("|x")
	notify(
		"verify.changed",
		{ account = "@anna:x", id = "v1", state = "asked", from = "Anna's phone" }
	)
	t:wait(50)
	t:type("y")
	t:keys("enter")
	t:wait(50)
	assert(
		#calls("verify.accept") == 1 and calls("verify.accept")[1].id == "v1",
		greed.json.encode(asked)
	)
	notify("verify.changed", {
		account = "@anna:x",
		id = "v1",
		state = "compare",
		emoji = { { "🐶", "Dog" }, { "🔑", "Key" } },
	})
	t:wait(50)
	local floats = t:floats()
	local shown = false
	for _, float in floats do
		if string.find(float, "🐶   🔑", 1, true) then
			shown = true
		end
	end
	assert(shown, "the emoji are shown")
	-- The other device saying they match first comes as compare again: the
	-- question already asked stays.
	notify("verify.changed", {
		account = "@anna:x",
		id = "v1",
		state = "compare",
		emoji = { { "🐶", "Dog" }, { "🔑", "Key" } },
	})
	t:wait(50)
	t:type("y")
	t:keys("enter")
	t:wait(50)
	local confirmed = calls("verify.confirm")
	assert(#confirmed == 1 and confirmed[1].same == true, greed.json.encode(asked))
end)

-- An alert from the fake in Plans, from Bea.
local function alert(notify: (method: string, params: any) -> (), extra: { [string]: any })
	local params: { [string]: any } = {
		account = "@anna:x",
		room = "!plans:x",
		room_name = "Plans",
		event = "$9",
		sender = { id = "@bea:x", name = "Bea" },
		body = "anna, lunch?",
		mention = true,
		direct = false,
	}
	for key, value in extra do
		params[key] = value
	end
	notify("alert", params)
end

local function needs_you(): boolean
	for _, need in core.attention.list() do
		if need.key == chat.alerts.key("matrix @anna:x", "!plans:x") then
			return true
		end
	end
	return false
end

test("an alert marks its room until you look; :chat-alerted goes there", function(t)
	greed.option.set("chat-alerts-desktop", false)
	greed.option.set("chat-alerts", "mentions")
	local notify = fake()
	t:buffer("|x")
	alert(notify, {})
	assert(needs_you(), "the room needs you")
	local need = core.attention.list()[1]
	assert(need.label == "Bea in Plans" and need.reason == "anna, lunch?", need.label)
	assert(need.tell == true, "the hub tells you of it")

	t:run("chat-alerted")
	t:wait(50)
	assert(chat.rooms.of(greed.view():buffer()), "the room is open")
	assert(not needs_you(), "looked at, it no longer needs you")

	-- A room you're looking at doesn't alert.
	alert(notify, { body = "here?" })
	assert(not needs_you(), "shown rooms don't alert")
end)

test("chat-alerts picks which messages alert", function()
	local function wanted(which: string, mention: boolean, direct: boolean): boolean
		greed.option.set("chat-alerts", which)
		return chat.alerts.wanted({
			room = "!r",
			room_name = "R",
			event = "$e",
			sender = { id = "@b:x", name = "B" },
			body = "hi",
			mention = mention,
			direct = direct,
		})
	end
	assert(wanted("mentions", true, false), "a mention")
	assert(wanted("mentions", false, true), "a direct message")
	assert(not wanted("mentions", false, false), "neither")
	assert(wanted("all", false, false), "all")
	assert(not wanted("off", true, true), "off")
	greed.option.set("chat-alerts", "mentions")
end)

test("a direct message is titled by who sent it; long ones are cut", function()
	local title, text = chat.alerts.said({
		room = "!d",
		room_name = "Bea",
		event = "$e",
		sender = { id = "@bea:x", name = "Bea" },
		body = string.rep("a", 300),
		mention = false,
		direct = true,
	})
	assert(title == "Bea", title)
	assert(#text < 300 and string.sub(text, -3) == "…", text)
end)

-- A Mattermost service with one channel, Ops, whose one post has a button
-- and a menu; what it was pressed and sent goes in `asked`.
local function integration(): (method: string, params: any) -> ()
	table.clear(asked)
	backend.reset()
	local notify = backend.use("mattermost", {
		rooms = function(): any
			return {
				{
					id = "ops",
					account = "anna",
					name = "Ops",
					kind = "room",
					unread = 0,
					mentions = 0,
					favourite = false,
					muted = false,
					encrypted = false,
				},
			}
		end,
		timeline = function(): any
			return {
				items = {
					{
						id = "p1",
						event = "p1",
						kind = "message",
						at = 1792660000000,
						sender = { id = "bot", name = "deploys" },
						text = "**Release 1.2**",
						replies = 0,
						reactions = {},
						edited = false,
						mine = false,
						actions = {
							{ id = "approve", name = "Approve" },
							{
								id = "where",
								name = "Where",
								options = { { text = "Prod", value = "prod" } },
							},
						},
						preview = {
							url = "https://plots.example/beds",
							title = "Garden plans",
							description = "Beds,\n tomatoes and compost",
							site = "Plots",
						},
					},
				},
			}
		end,
		commands = function(): any
			return { { trigger = "away", hint = "", description = "Set your status to away" } }
		end,
		send = function(params: any)
			table.insert(asked, { method = "send", params = params })
			return nil
		end,
		press = function(params: any)
			table.insert(asked, { method = "press", params = params })
			return nil
		end,
		read = function()
			return nil
		end,
		["timeline.close"] = function()
			return nil
		end,
	}, { "commands" })
	notify("account.changed", {
		id = "anna",
		server = "https://mm",
		name = "anna",
		state = { state = "ready" },
	})
	return notify
end

test("a message's buttons show; enter presses one, or picks from a menu", function(t)
	integration()
	local buffer = on_message(t, "p1")
	local text = buffer:text()
	assert(string.find(text, "[ Approve ] [ Where ▾ ]  (enter)", 1, true), text)
	t:keys("enter")
	t:keys("enter") -- Approve, the first
	t:wait(50)
	local pressed = calls("press")
	assert(
		#pressed == 1 and pressed[1].event == "p1" and pressed[1].action == "approve",
		greed.json.encode(asked)
	)
	t:keys("alt-b")
	t:keys("down")
	t:keys("enter") -- Where: Prod
	t:wait(50)
	pressed = calls("press")
	assert(
		#pressed == 2 and pressed[2].action == "where" and pressed[2].option == "prod",
		greed.json.encode(asked)
	)
end)

test("alt-/ picks a command into the box", function(t)
	integration()
	on_message(t, "p1")
	t:keys("alt-/")
	t:wait(50)
	t:keys("enter")
	t:wait(50)
	local r = chat.rooms.of(greed.view():buffer())
	assert(r and r.view:input() == "/away ", r and r.view:input())
end)

-- Messages the fake tells of, kept to search: Bea's in Plans, Cal's in
-- Quiet, and Anna's own in Plans.
local function told(notify: (method: string, params: any) -> ())
	local function said(room: string, name: string, event: string, who: string, text: string): any
		local id = `@{string.lower(who)}:x`
		return {
			room = room,
			room_name = name,
			event = event,
			sender = { id = id, name = who },
			at = 1792660000000 + #event,
			text = text,
			mine = who == "Anna",
			direct = false,
		}
	end
	notify("messages", {
		account = "@anna:x",
		messages = {
			said("!plans:x", "Plans", "$1", "Bea", "lunch at noon?"),
			said("!quiet:x", "Quiet", "$q1", "Cal", "lunch tomorrow, noon or so"),
			said("!plans:x", "Plans", "$a1", "Anna", "noon is fine"),
		},
	})
end

-- What `text` finds, as chat's search does it, by event.
local function finds(t: any, text: string, only: any?): { string }
	local events: { string } = {}
	local done = false
	greed.spawn(function()
		local found, why = chat.search.search(text, only)
		assert(found, why)
		for _, one in found do
			table.insert(events, one.item.event or "")
		end
		done = true
	end)
	t:wait_for(function(): boolean
		return done
	end)
	table.sort(events)
	return events
end

test(
	"as an account comes in, its rooms' older messages are kept, back to the horizon once",
	function(t)
		backend.reset()
		chat.index.BETWEEN = 0
		local now = os.time() * 1000
		local function said(event: string, text: string, ago: number): any
			return {
				room = "!yard:x",
				room_name = "Yard",
				event = event,
				sender = { id = "@cal:x", name = "Cal" },
				at = now - ago,
				text = text,
				mine = false,
				direct = false,
			}
		end
		-- The room's history, newest first, given two at a time.
		local history = {
			said("$y4", "rake", 1000),
			said("$y3", "hose", 2000),
			said("$y2", "shed", 3000),
			said("$y1", "spade", 4000),
		}
		local pages: { string } = {}
		local notify = backend.use("matrix", {
			rooms = function(): any
				return { { id = "!yard:x", account = "@anna:x", name = "Yard", kind = "room" } }
			end,
			history = function(params: any): any
				table.insert(pages, params.before or "newest")
				local from = tonumber(params.before) or 0
				local page = {}
				for i = from + 1, math.min(from + 2, #history) do
					table.insert(page, history[i])
				end
				return {
					messages = page,
					before = if from + 2 < #history then tostring(from + 2) else nil,
				}
			end,
		}, { "history" })
		local ready = { id = "@anna:x", server = "https://x", state = { state = "ready" } }
		notify("account.changed", ready)
		t:wait_for(function(): boolean
			return #pages == 2
		end)
		t:wait(50)
		assert(pages[1] == "newest" and pages[2] == "2", table.concat(pages, " "))
		local found = finds(t, "spade")
		assert(#found == 1 and found[1] == "$y1", table.concat(found, " "))

		-- Coming in again, as after a restart: back to where it has messages.
		backend.reset()
		backend.use("matrix", {
			rooms = function(): any
				return { { id = "!yard:x", account = "@anna:x", name = "Yard", kind = "room" } }
			end,
			history = function(params: any): any
				table.insert(pages, params.before or "newest")
				return { messages = { history[1], history[2] }, before = "2" }
			end,
		}, { "history" })
		table.clear(pages)
		notify("account.changed", ready)
		t:wait_for(function(): boolean
			return #pages == 1
		end)
		t:wait(100)
		assert(#pages == 1, "one page, which it had: " .. table.concat(pages, " "))
	end
)

test("chat's search finds what the services told of, in Greed's query language", function(t)
	local notify = fake()
	told(notify)
	t:wait(50)
	local found = finds(t, "lunch")
	assert(#found == 2 and found[1] == "$1" and found[2] == "$q1", table.concat(found, " "))
	found = finds(t, "lunch from:bea")
	assert(#found == 1 and found[1] == "$1", table.concat(found, " "))
	found = finds(t, "noon in:quiet")
	assert(#found == 1 and found[1] == "$q1", table.concat(found, " "))
	found = finds(t, "noon is:mine")
	assert(#found == 1 and found[1] == "$a1", table.concat(found, " "))
	-- Deleted, it's found no more.
	notify("unsaid", { account = "@anna:x", room = "!quiet:x", event = "$q1" })
	t:wait(50)
	found = finds(t, "lunch")
	assert(#found == 1 and found[1] == "$1", table.concat(found, " "))
end)

test("search everywhere finds chat messages with in:chat", function(t)
	told(fake())
	t:wait(50)
	local labels: { string } = {}
	local done = false
	greed.spawn(function()
		local hits, troubles = core.everywhere.search("lunch from:bea in:chat")
		assert(#troubles == 0, table.concat(troubles, "; "))
		for _, hit in hits do
			table.insert(labels, `{hit.source}:{hit.label}`)
		end
		done = true
	end)
	t:wait_for(function(): boolean
		return done
	end)
	assert(
		#labels == 1 and labels[1] == "chat:Plans · Bea: lunch at noon?",
		table.concat(labels, " | ")
	)
end)

test("/ in the list searches every account; the message picked opens in its room", function(t)
	local notify = fake()
	told(notify)
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("/")
	t:type("lunch from:bea")
	t:keys("enter")
	t:wait(100)
	t:keys("enter") -- the one found
	t:wait(100)
	local view = greed.view()
	local r = chat.rooms.of(view:buffer())
	assert(r and r.room == "!plans:x", "the room opens")
	local value = r.view:value_at(view:cursor())
	assert(value and value.item.event == "$1", "on the message found")
	assert(
		string.find(
			chat.search.label({
				account = "matrix @anna:x",
				room = "!plans:x",
				room_name = "Plans",
				item = value.item,
			}),
			"^Plans · Bea: lunch at noon%? · "
		),
		"how it reads"
	)
end)

test("alt-s in a room searches only that room", function(t)
	local notify = fake()
	told(notify)
	t:wait(50)
	local only = { account = "matrix @anna:x", room = "!plans:x" }
	local found = finds(t, "noon", only)
	assert(#found == 2 and found[1] == "$1" and found[2] == "$a1", table.concat(found, " "))
	on_message(t, "$1")
	t:keys("alt-s")
	t:type("noon")
	t:keys("enter")
	t:wait(100)
	local picked = greed.view():buffer():text()
	assert(string.find(picked, "Anna: noon is fine", 1, true), picked)
	assert(not string.find(picked, "Quiet", 1, true), "only this room's: " .. picked)
end)

test("the first link in a message, without what ends the sentence", function()
	local first = chat.rooms.first_link
	assert(
		first("see https://a.example/x.") == "https://a.example/x",
		first("see https://a.example/x.")
	)
	assert(first("(https://a.example/y) and http://b.example") == "https://a.example/y")
	assert(first("no link here") == nil)
end)

test("a preview that came with a message shows under it", function(t)
	integration()
	local buffer = on_message(t, "p1")
	local text = buffer:text()
	assert(
		string.find(text, "▎ Plots · Garden plans\n▎ Beds, tomatoes and compost", 1, true),
		text
	)
end)

test("a link is previewed by a service that can; once for each link", function(t)
	local notify = fake()
	backend.can.matrix = { previews = true }
	on_message(t, "$1")
	local item = {
		id = "9",
		event = "$9",
		kind = "message",
		at = 1792660060000,
		sender = { id = "@bea:x", name = "Bea" },
		text = "plots: https://plots.example/beds.",
		replies = 0,
		reactions = {},
		edited = false,
		mine = false,
	}
	notify("timeline.changed", {
		account = "@anna:x",
		room = "!plans:x",
		changes = { { op = "insert", at = 3, item = item } },
	})
	t:wait(100)
	local asked_for = calls("preview")
	assert(
		#asked_for == 1 and asked_for[1].url == "https://plots.example/beds",
		greed.json.encode(asked)
	)
	local text = greed.view():buffer():text()
	assert(string.find(text, "▎ plots.example · Plots of land", 1, true), text)
end)

-- A Matrix service whose one room is `shown` (an invite or a room), with a
-- directory listing Garden; what it's asked to join and leave goes in
-- `asked`.
local function joining(shown: { [string]: any }): (method: string, params: any) -> ()
	table.clear(asked)
	backend.reset()
	local function room(fields: { [string]: any }): { [string]: any }
		local made: { [string]: any } = {
			account = "@anna:x",
			unread = 0,
			mentions = 0,
			favourite = false,
			muted = false,
			encrypted = false,
		}
		for key, value in fields do
			made[key] = value
		end
		return made
	end
	local notify = backend.use("matrix", {
		rooms = function(): any
			return { room(shown) }
		end,
		directory = function(): any
			return {
				{
					id = "!garden:x",
					name = "Garden",
					topic = "Beds",
					members = 3,
					address = "#garden:x",
				},
			}
		end,
		join = function(params: any): any
			table.insert(asked, { method = "join", params = params })
			return { room = "!garden:x" }
		end,
		leave = function(params: any)
			table.insert(asked, { method = "leave", params = params })
			return nil
		end,
		timeline = function(): any
			return { items = {} }
		end,
		read = function()
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

test("+ offers the rooms you could join; the one picked is joined and opens", function(t)
	joining({ id = "!quiet:x", name = "Quiet", kind = "room" })
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("+")
	t:wait(50)
	t:keys("down")
	t:keys("enter") -- Garden
	t:wait(100)
	local joined = calls("join")
	assert(#joined == 1 and joined[1].room == "!garden:x", greed.json.encode(asked))
	local r = chat.rooms.of(greed.view():buffer())
	assert(r and r.room == "!garden:x" and r.name == "Garden", "Garden opens")
	assert(chat.join.label({
		id = "!g",
		name = "Garden",
		topic = "Beds",
		members = 3,
		address = "#garden:x",
	}) == "Garden · Beds · 3 members · #garden:x")
end)

test("+ joins a room by its address", function(t)
	joining({ id = "!quiet:x", name = "Quiet", kind = "room" })
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("+")
	t:wait(50)
	t:keys("enter") -- by its address or id
	t:wait(50)
	t:type("#garden:x")
	t:keys("enter")
	t:wait(100)
	local joined = calls("join")
	assert(#joined == 1 and joined[1].room == "#garden:x", greed.json.encode(asked))
end)

test("enter on an invite: n says no, y joins", function(t)
	joining({ id = "!plans:x", name = "Plans", kind = "invite" })
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("enter")
	t:keys("n")
	t:wait(50)
	local left = calls("leave")
	assert(#left == 1 and left[1].room == "!plans:x", greed.json.encode(asked))
	t:keys("enter")
	t:keys("y")
	t:wait(50)
	local joined = calls("join")
	assert(#joined == 1 and joined[1].room == "!plans:x", greed.json.encode(asked))
end)

test("- leaves the room under the cursor after asking", function(t)
	joining({ id = "!quiet:x", name = "Quiet", kind = "room" })
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	t:keys("-")
	t:keys("x")
	t:wait(50)
	assert(#calls("leave") == 0, "anything but y keeps it")
	t:keys("-")
	t:keys("y")
	t:wait(50)
	local left = calls("leave")
	assert(#left == 1 and left[1].room == "!quiet:x", greed.json.encode(asked))
end)

-- Puts `item` (with what `extra` adds) into the fake's open Plans room.
local function arrives(notify: (method: string, params: any) -> (), extra: { [string]: any })
	local item: { [string]: any } = {
		id = "9",
		event = "$9",
		kind = "message",
		at = 1792660060000,
		sender = { id = "@bea:x", name = "Bea" },
		text = "",
		replies = 0,
		reactions = {},
		edited = false,
		mine = false,
	}
	for key, value in extra do
		item[key] = value
	end
	notify("timeline.changed", {
		account = "@anna:x",
		room = "!plans:x",
		changes = { { op = "insert", at = 3, item = item } },
	})
end

test("a poll shows its answers and votes; enter votes for the one picked", function(t)
	local notify = fake()
	on_message(t, "$1")
	arrives(notify, {
		kind = "poll",
		text = "What to plant?",
		poll = {
			question = "What to plant?",
			answers = {
				{ id = "t", text = "Tomatoes", votes = 2, mine = false },
				{ id = "b", text = "Beans", votes = 1, mine = true },
			},
			picks = 1,
			ended = false,
		},
	})
	t:wait(50)
	local buffer = greed.view():buffer()
	local text = buffer:text()
	assert(
		string.find(text, "○ Tomatoes  2 votes\n  ● Beans  1 vote\n  enter votes", 1, true),
		text
	)
	local r = chat.rooms.of(buffer)
	assert(r, "the room is open")
	local line = r.view:line_of(function(value: any): boolean
		return value ~= nil and value.item.event == "$9"
	end)
	greed.view():set_cursor(buffer:line_start(line :: number))
	t:keys("enter")
	t:keys("enter") -- Tomatoes
	t:wait(50)
	local voted = calls("vote")
	assert(
		#voted == 1 and voted[1].event == "$9" and voted[1].answers[1] == "t",
		greed.json.encode(asked)
	)
end)

test("a location shows where, and opens on OpenStreetMap", function(t)
	local notify = fake()
	on_message(t, "$1")
	arrives(notify, {
		kind = "location",
		text = "The allotment",
		location = { latitude = 59.3293, longitude = 18.0686 },
	})
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, "📍 59.3293, 18.0686  enter opens the map", 1, true), text)
	assert(
		chat.rooms.map_link({ latitude = 59.3293, longitude = 18.0686 })
			== "https://www.openstreetmap.org/?mlat=59.3293&mlon=18.0686#map=16/59.3293/18.0686"
	)
end)

test("recordings play with mpv, else ffplay, where one is installed", function()
	local command = chat.rooms.player("/tmp/x.ogg")
	if greed.which("mpv") then
		assert(command and command[1] == "mpv" and command[#command] == "/tmp/x.ogg")
	elseif greed.which("ffplay") then
		assert(command and command[1] == "ffplay" and command[#command] == "/tmp/x.ogg")
	else
		assert(command == nil)
	end
end)

-- A Matrix service with the space Allotments, holding Beds (joined, so
-- listed under it) and Paths (not joined), and a room in no space.
local function allotments(): (method: string, params: any) -> ()
	table.clear(asked)
	backend.reset()
	local function room(fields: { [string]: any }): { [string]: any }
		local made: { [string]: any } = {
			account = "@anna:x",
			kind = "room",
			unread = 0,
			mentions = 0,
			favourite = false,
			muted = false,
			encrypted = false,
		}
		for key, value in fields do
			made[key] = value
		end
		return made
	end
	local notify = backend.use("matrix", {
		rooms = function(): any
			return {
				room({ id = "!kitchen:x", name = "Kitchen" }),
				room({ id = "!allot:x", name = "Allotments", kind = "space" }),
				room({ id = "!beds:x", name = "Beds", parent = "!allot:x" }),
			}
		end,
		space = function(params: any): any
			table.insert(asked, { method = "space", params = params })
			return {
				{ id = "!beds:x", name = "Beds", members = 4, joined = true, via = {} },
				{
					id = "!paths:x",
					name = "Paths",
					topic = "Gravel",
					members = 2,
					joined = false,
					via = { "far.example" },
				},
			}
		end,
		join = function(params: any): any
			table.insert(asked, { method = "join", params = params })
			return { room = params.room }
		end,
		timeline = function(): any
			return { items = {} }
		end,
		read = function()
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

test("rooms in a space are listed under it, after the rooms in none", function(t)
	allotments()
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	local text = greed.view():buffer():text()
	local kitchen = string.find(text, "#  Kitchen", 1, true)
	local space = string.find(text, "◆  Allotments", 1, true)
	local beds = string.find(text, "#    Beds", 1, true)
	assert(kitchen and space and beds and kitchen < space and space < beds, text)
end)

test(
	"enter on a space offers its rooms; one you're not in is joined through its servers",
	function(t)
		allotments()
		t:buffer("|x")
		t:run("chat")
		t:wait(50)
		local buffer = greed.view():buffer()
		local line = string.find(buffer:text(), "◆  Allotments", 1, true)
		assert(line, "the space is listed")
		greed.view():set_cursor(line - 1)
		t:keys("enter")
		t:wait(50)
		local listed = calls("space")
		assert(#listed == 1 and listed[1].room == "!allot:x", greed.json.encode(asked))
		t:keys("down")
		t:keys("enter") -- Paths, not joined
		t:wait(100)
		local joined = calls("join")
		assert(
			#joined == 1 and joined[1].room == "!paths:x" and joined[1].via[1] == "far.example",
			greed.json.encode(asked)
		)
		local r = chat.rooms.of(greed.view():buffer())
		assert(r and r.room == "!paths:x", "Paths opens")
		assert(
			chat.join.held_label({ id = "!b", name = "Beds", members = 4, joined = true })
				== "✓ Beds · 4 members"
		)
	end
)

test(
	":chat is one float of the tab, rooms open in it, and :chat again shows the rooms in it",
	function(t)
		local panes = require("@panes")
		fake()
		t:buffer("|x")
		t:run("chat")
		t:wait(50)
		local window = greed.view()
		assert(window:buffer():kind() == "chat", window:buffer():kind())
		assert(table.find(panes.floats.all(), window), "a float of the tab, which alt-f hides")
		t:keys("enter")
		t:wait(50)
		assert(
			greed.view() == window and window:buffer():kind() == "chat-room",
			"the room opens in it"
		)
		panes.pane():focus()
		assert(greed.view() ~= window, "back in the file")
		t:run("chat")
		assert(#panes.floats.all() == 1, "still one chat float")
		assert(
			greed.view() == window and window:buffer():kind() == "chat",
			"it comes back showing the rooms"
		)
	end
)

test("the rooms opened show as a bar over a room; tab and alt and a number go to them", function(t)
	fake()
	chat.rooms.forget_recent()
	t:buffer("|x")
	t:run("chat")
	t:wait(50)
	local window = greed.view()
	local function in_room(): string?
		local r = chat.rooms.of(window:buffer())
		return if r then r.room else nil
	end
	t:keys("enter") -- Plans, with three unread
	t:wait(50)
	assert(not string.find(window:buffer():text(), " 1 Plans", 1, true), "no bar for one room")
	t:run("chat-close")
	local buffer = window:buffer()
	local plans = string.find(buffer:text(), "Plans", 1, true)
	assert(plans, "Plans is listed")
	assert(window:cursor() == buffer:line_start(buffer:line_of(plans - 1)), "back on the room left")
	local quiet = string.find(buffer:text(), "Quiet", 1, true)
	assert(quiet, "Quiet is listed")
	window:set_cursor(quiet - 1)
	t:keys("enter") -- Quiet
	t:wait(50)
	local text = window:buffer():text()
	assert(string.find(text, " 1 Plans 3  2 Quiet ", 1, true), text)
	assert(in_room() == "!quiet:x", "in Quiet")
	t:keys("tab")
	t:wait(50)
	assert(in_room() == "!plans:x", "tab goes round to Plans")
	t:keys("alt-2")
	t:wait(50)
	assert(in_room() == "!quiet:x", "alt-2 to Quiet")
end)

test(
	"in the chat session the rooms are a sidebar; a room opens beside it, q goes back to it",
	function(t)
		fake()
		t:buffer("|x")
		chat.sidebar()
		t:wait(50)
		local panel = greed.view()
		assert(panel:buffer():kind() == "chat" and not panel:is_pane(), "the list is a panel")
		t:keys("enter") -- Plans
		t:wait(50)
		local main = greed.view()
		assert(
			main:is_pane() and main:buffer():kind() == "chat-room",
			"the room opens in the main view"
		)
		assert(panel:valid() and panel:buffer():kind() == "chat", "the sidebar stays")
		t:run("chat-close")
		assert(greed.view() == panel, "back to the sidebar")
		assert(main:buffer():kind() == "chat-room", "the room stays beside it")
		chat.sidebar()
		assert(greed.view() == panel, "one sidebar")
		panel:close()
	end
)

test("a server is named without its scheme or a slash at the end", function()
	assert(chat.host("https://matrix.org/") == "matrix.org")
	assert(chat.host("http://127.0.0.1:38411") == "127.0.0.1:38411")
	assert(chat.host("mm.evroc.com") == "mm.evroc.com")
end)

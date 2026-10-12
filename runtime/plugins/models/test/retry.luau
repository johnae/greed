local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
-- The module itself, for its stream to stand in for.
local network: any = require("../network")

local ASKED: models.TurnRequest = { said = { { role = "user", text = "hi" } } }

local function event(content: string): string
	return `data: {greed.json.encode({ choices = { { delta = { content = content } } } })}\n\n`
end

-- A server that answers each request as `answers` say, in order: a list of
-- what each read gives (a string, or { fail = why } or "stall" for nothing
-- until the read's time runs out), or { status, headers } for a refusal, or
-- { fail = why } when it can't be reached. Says how many requests came and
-- each read's time limit.
local function serve(answers: { any }): { opened: number, limits: { number? } }
	models.providers.standin = { kind = "openai", url = "http://127.0.0.1:9/v1" }
	models.roles.standin = { provider = "standin", model = "m" }
	local seen = { opened = 0, limits = {} :: { number? } }
	network.stream = function(_request: greed.HttpRequest): (any, string?)
		seen.opened += 1
		local answer = answers[seen.opened] or { "stall" }
		if answer.fail then
			return nil, answer.fail
		end
		local closed = false
		local reads = 0
		return {
			status = answer.status or 200,
			headers = answer.headers or {},
			read = function(_, limit: number?): (string?, string?)
				table.insert(seen.limits, limit)
				if closed or answer.status then
					return nil, nil
				end
				reads += 1
				local piece = answer[reads]
				if piece == nil then
					return "data: [DONE]\n\n", nil
				elseif piece == "stall" then
					assert(limit, "a stalled read without a limit waits for ever")
					greed.sleep(limit)
					return nil, "timed out"
				elseif type(piece) == "table" then
					return nil, piece.fail
				end
				return event(piece), nil
			end,
			close = function()
				closed = true
			end,
		},
			nil
	end
	return seen
end

local function done()
	network.stream = function(request: greed.HttpRequest): (greed.HttpStream?, string?)
		return greed.http.stream(request)
	end
	models.roles.standin = nil
	models.providers.standin = nil
end

test("a server that never answers is given up on, tried again once, and says so", function()
	local seen = serve({ { "stall" }, { "stall" } })
	local retried: { string } = {}
	local turn, err, again = models.turn("standin", ASKED, nil, nil, nil, nil, function(why)
		table.insert(retried, why)
	end)
	done()
	assert(turn == nil and err == "no reply for 270s", tostring(err))
	assert(again, "trying again later may work")
	assert(seen.opened == 2, "tried twice")
	assert(#retried == 1 and retried[1] == "no reply for 270s", retried[1])
	assert(seen.limits[1] == 270000, "the first bytes may take three times the gap")
end)

test("a connection reset before anything came is tried again, and that answer counts", function()
	local seen = serve({ { { fail = "Connection reset by peer" } }, { "Hel", "lo" } })
	local said: { string } = {}
	local turn, err = models.turn("standin", ASKED, function(text)
		table.insert(said, text)
	end)
	done()
	assert(turn and turn.text == "Hello", tostring(err))
	assert(seen.opened == 2, "tried twice")
	assert(table.concat(said) == "Hello", "only the answer that worked was passed on")
end)

test("a server that stops after text came isn't asked again: that would say it twice", function()
	local seen = serve({ { "Hel", "stall" } })
	local turn, err, again = models.turn("standin", ASKED, function() end)
	done()
	assert(turn == nil and err == "no reply for 90s", tostring(err))
	assert(again, "you can ask it to go on")
	assert(seen.opened == 1, "asked once")
	assert(seen.limits[2] == 90000, "a gap may be 90s")
end)

test("how long a gap may be: the role's, its provider's, or the option", function()
	local seen = serve({ { "Hel", "stall" }, { "Hel", "stall" }, { "Hel", "stall" } })
	greed.option.set("models-idle-timeout", 20)
	models.turn("standin", ASKED, function() end)
	assert(seen.limits[2] == 20000, tostring(seen.limits[2]))
	local provider: models.Provider = assert(models.providers.standin)
	provider.idle = 10
	models.turn("standin", ASKED, function() end)
	assert(seen.limits[4] == 10000, tostring(seen.limits[4]))
	local role: models.Role = assert(models.roles.standin)
	role.idle = 5
	models.turn("standin", ASKED, function() end)
	assert(seen.limits[6] == 5000, tostring(seen.limits[6]))
	greed.option.set("models-idle-timeout", 90)
	done()
end)

test("too many requests waits as long as the server says before trying again", function()
	local seen = serve({ { status = 429, headers = { ["retry-after"] = "7" } }, { "ok" } })
	local waits: { number } = {}
	local started = greed.now()
	local turn, err = models.turn("standin", ASKED, nil, nil, nil, nil, function(_, ms)
		table.insert(waits, ms)
	end)
	done()
	assert(turn and turn.text == "ok", tostring(err))
	assert(waits[1] == 7000, tostring(waits[1]))
	assert(greed.now() - started >= 7000, "it waited")
	assert(seen.opened == 2, "tried twice")
end)

test("a refusal that won't change isn't tried again", function()
	local seen = serve({ { status = 401 }, { "ok" } })
	local turn, err, again = models.turn("standin", ASKED)
	done()
	assert(turn == nil and string.find(err or "", "401", 1, true), tostring(err))
	assert(not again, "asking again won't help")
	assert(seen.opened == 1, "asked once")
end)

test("stopping while it waits to try again stops at once, and nothing more is sent", function(t)
	local seen = serve({ { status = 503, headers = { ["retry-after"] = "20" } }, { "ok" } })
	local stop: (() -> ())? = nil
	local result: { any }? = nil
	greed.spawn(function()
		result = {
			models.turn("standin", ASKED, nil, function(close)
				stop = close
			end),
		}
	end)
	t:wait(50)
	assert(stop and result == nil, "waiting to try again")
	stop()
	t:wait(50)
	assert(result and result[1] == nil and result[2] == "stopped", "stopped")
	t:wait(30000)
	done()
	assert(seen.opened == 1, "never sent again")
end)

test(
	"Mistral, which sends a tool call whole once it's written, waits ten minutes for quiet",
	function()
		models.roles.test_quiet = { provider = "mistral", model = "mistral-large-4" }
		local idle = models.idle("test_quiet")
		models.roles.test_quiet = nil
		assert(idle == 600, tostring(idle))
	end
)

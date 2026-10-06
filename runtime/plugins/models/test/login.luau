local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
-- The module itself, which the plugin keeps to itself, for its post to stand in for.
local login: any = require("../login")

-- Stands in for the sign-in server: each POST gets the next answer for its
-- URL, and what was sent is kept.
local function serve(answers: { [string]: { { status: number, body: any } } }): { any }
	local sent = {}
	login.post = function(url: string, body: any, kind: string): (number?, any)
		table.insert(sent, { url = url, body = body, kind = kind })
		local queue = answers[url]
		local answer = queue and table.remove(queue, 1)
		if answer == nil then
			return nil, "nothing here"
		end
		return answer.status, answer.body
	end
	return sent
end

local BERGET = models.login.logins.berget
local REFRESH = "https://api.berget.ai/v1/auth/refresh"

local function keep(tokens: any)
	greed.secrets.set("berget-login", greed.json.encode(tokens))
end

test("signing in shows the link and code, waits for you, and keeps the tokens", function(t)
	local sent = serve({
		[BERGET.device_url] = {
			{
				status = 200,
				body = {
					device_code = "dev",
					user_code = "ABCD-EFGH",
					verification_uri = "https://auth.berget.ai/device",
					verification_uri_complete = "https://auth.berget.ai/device?code=ABCD-EFGH",
					expires_in = 600,
					interval = 5,
				},
			},
		},
		[BERGET.token_url] = {
			{ status = 400, body = { error = "authorization_pending" } },
			{ status = 400, body = { error = "slow_down" } },
			{
				status = 200,
				body = { access_token = "a1", refresh_token = "r1", expires_in = 300 },
			},
		},
	})
	local shown: any, ok: boolean?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("berget", function(started)
			shown = started
		end)
	end)
	assert(shown and shown.code == "ABCD-EFGH" and shown.minutes == 10, "it shows the code")
	assert(string.find(shown.complete, "code=ABCD-EFGH", 1, true) ~= nil, shown.complete)
	assert(sent[1].body.client_id == "berget-code" and sent[1].kind == "form")
	t:wait(5000)
	assert(ok == nil, "still waiting")
	t:wait(5000)
	-- slow_down: the next poll comes 10 seconds later.
	t:wait(5000)
	assert(ok == nil, "waits longer after slow_down")
	t:wait(5000)
	assert(ok == true, tostring(err))
	assert(sent[#sent].body.grant_type == "urn:ietf:params:oauth:grant-type:device_code")
	assert(login.signed_in("berget"))
	assert(login.token("berget") == "a1")
end)

test("signing in turned down in the browser says so", function(t)
	serve({
		[BERGET.device_url] = {
			{
				status = 200,
				body = { device_code = "d", user_code = "C", verification_uri = "u", interval = 1 },
			},
		},
		[BERGET.token_url] = { { status = 400, body = { error = "access_denied" } } },
	})
	local ok: boolean?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("berget", function() end)
	end)
	t:wait(1000)
	assert(ok == false and string.find(tostring(err), "turned down", 1, true), tostring(err))
	assert(not login.signed_in("berget"))
end)

test("a token that's about to run out is renewed first, once for requests at once", function(t)
	keep({ access = "old", refresh = "r0", expires = os.time() + 30 })
	local sent = serve({
		[REFRESH] = {
			{ status = 200, body = { token = "new", refresh_token = "r1", expires_in = 900 } },
		},
	})
	local first, second
	greed.spawn(function()
		first = login.token("berget")
	end)
	greed.spawn(function()
		second = login.token("berget")
	end)
	t:wait(10)
	assert(first == "new" and second == "new", `{first} {second}`)
	assert(#sent == 1 and sent[1].body.refresh_token == "r0" and sent[1].kind == "json")
	-- The new refresh token is kept, and a fresh token needs no renewing.
	assert(login.token("berget") == "new" and #sent == 1)
	local kept = greed.json.decode(greed.secrets.get("berget-login") :: string)
	assert(kept.refresh == "r1", kept.refresh)
end)

test("when renewing fails, it says to sign in again", function()
	keep({ access = "old", refresh = "r0", expires = os.time() - 1 })
	serve({ [REFRESH] = { { status = 401, body = { error = "invalid_grant" } } } })
	local token, err = login.token("berget")
	assert(token == nil and string.find(err, ":login berget", 1, true), tostring(err))
end)

test("signed in, the provider uses the token instead of a key; signed out, the key", function(t)
	models.roles.coding = { provider = "berget", model = "big" }
	keep({ access = "tok", refresh = "r", expires = os.time() + 3600 })
	local line = table.concat(models.describe(), "\n")
	assert(
		string.find(line, "coding: big at berget (https://api.berget.ai/v1), signed in", 1, true),
		line
	)
	t:run("logout", { "berget" })
	assert(not login.signed_in("berget"))
	line = table.concat(models.describe(), "\n")
	assert(string.find(line, "coding: big at berget", 1, true), line)
	assert(not string.find(line, "signed in", 1, true), line)
	models.roles.coding = nil
end)

test("not signed in, a token says how to sign in", function()
	local token, err = login.token("berget")
	assert(token == nil and string.find(err, ":login berget", 1, true), tostring(err))
end)

test("a login added from config signs in and renews with OAuth's refresh", function(t)
	login.logins.acme = {
		title = "Acme AI",
		device_url = "https://auth.acme.example/device",
		token_url = "https://auth.acme.example/token",
		client_id = "acme-cli",
		scope = "openid offline_access",
	}
	models.providers.acme = { kind = "openai", url = "https://api.acme.example/v1", login = "acme" }
	models.roles.coding = { provider = "acme", model = "acme-large" }
	greed.secrets.set(
		"acme-login",
		greed.json.encode({ access = "old", refresh = "r0", expires = os.time() - 1 })
	)
	local sent = serve({
		["https://auth.acme.example/token"] = {
			{
				status = 200,
				body = { access_token = "fresh", refresh_token = "r1", expires_in = 600 },
			},
		},
	})
	assert(login.token("acme") == "fresh")
	assert(sent[1].body.grant_type == "refresh_token" and sent[1].body.refresh_token == "r0")
	assert(sent[1].kind == "form")
	local line = table.concat(models.describe(), "\n")
	assert(
		string.find(line, "coding: acme-large at acme", 1, true)
			and string.find(line, "signed in", 1, true),
		line
	)
	login.logins.acme = nil
	models.providers.acme = nil
	models.roles.coding = nil
end)

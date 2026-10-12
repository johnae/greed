local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
-- The module itself, which the plugin keeps to itself, for its post to stand in for.
local login: any = require("../login")

-- Stands in for the sign-in server: each request gets the next answer for
-- its URL, and what was sent is kept.
local function serve(answers: { [string]: { { status: number, body: any } } }): { any }
	local sent: { any } = {}
	local function answer(url: string): (number?, any)
		local queue = answers[url]
		local next_answer = queue and table.remove(queue, 1)
		if next_answer == nil then
			return nil, "nothing here"
		end
		return next_answer.status, next_answer.body
	end
	login.post = function(url: string, body: any, kind: string): (number?, any)
		table.insert(sent, { method = "POST", url = url, body = body, kind = kind })
		return answer(url)
	end
	login.get = function(url: string): (number?, any)
		table.insert(sent, { method = "GET", url = url })
		return answer(url)
	end
	return sent
end

local BERGET: any = models.login.logins.berget
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
	local shown: any, ok: string?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("berget", function(started)
			shown = started
		end)
	end)
	assert(shown and shown.code == "ABCD-EFGH" and shown.minutes == 10, "it shows the code")
	assert(string.find(shown.complete, "code=ABCD-EFGH", 1, true) ~= nil, shown.complete)
	assert(sent[1].body.client_id == "berget-code" and sent[1].kind == "form")
	t:wait(5000)
	assert(ok == nil and err == nil, "still waiting")
	t:wait(5000)
	-- slow_down: the next poll comes 10 seconds later.
	t:wait(5000)
	assert(ok == nil and err == nil, "waits longer after slow_down")
	t:wait(5000)
	assert(ok ~= nil, tostring(err))
	assert(sent[#sent].body.grant_type == "urn:ietf:params:oauth:grant-type:device_code")
	assert(login.signed_in("berget"))
	assert(login.token("berget") == "a1")
end)

test("signing in with no keyring to reach keeps the tokens in the file, and says so", function(t)
	t:keyring("greed-test-no-such-keyring")
	serve({
		[BERGET.device_url] = {
			{
				status = 200,
				body = { device_code = "d", user_code = "C", verification_uri = "u", interval = 1 },
			},
		},
		[BERGET.token_url] = {
			{
				status = 200,
				body = { access_token = "a1", refresh_token = "r1", expires_in = 300 },
			},
		},
	})
	t:buffer("|x")
	t:run("login", { "berget" })
	t:wait(1000)
	local said = t:messages()
	local last = said[#said] or ""
	assert(string.find(last, "signed in to Berget", 1, true), last)
	assert(
		string.find(last, "secrets.json, since the system keyring couldn't be reached", 1, true),
		last
	)
	assert(login.signed_in("berget"), "found in the file")
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
	local ok: string?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("berget", function() end)
	end)
	t:wait(1000)
	assert(ok == nil and string.find(tostring(err), "turned down", 1, true), tostring(err))
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

test("signing in to a provider with a key asks for the key", function(t)
	t:buffer("|x")
	t:run("login", { "mistral" })
	t:type("key")
	t:keys("enter")
	t:keys("s k - 1 enter")
	assert(greed.secrets.get("mistral") == "sk-1", "kept")
	assert(models.key_state("mistral") ~= nil, "and it shows as set")
	greed.secrets.set("mistral", "")
end)

-- Vibe: Mistral's browser sign-in, which ends with an API key for the plan.
local VIBE = "https://console.mistral.ai/api/vibe/sign-in"
local POLL = `{VIBE}/p1`

local function started(fields: { [string]: any }?): { status: number, body: any }
	local body: { [string]: any } = {
		process_id = "p1",
		sign_in_url = "https://console.mistral.ai/vibe/sign-in/p1",
		poll_url = POLL,
		expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 600),
	}
	if fields then
		for key, value in fields do
			body[key] = value
		end
	end
	return { status = 200, body = body }
end

-- base64url of the SHA-256 of `verifier`, as PKCE's S256 makes it.
local function challenge_of(verifier: string): string
	local raw = string.gsub(greed.hash.sha256(verifier), "%x%x", function(byte: string): string
		return string.char(tonumber(byte, 16) :: number)
	end)
	local encoded = string.gsub(greed.base64.encode(raw), "=+$", "")
	return (string.gsub(encoded, "[+/]", { ["+"] = "-", ["/"] = "_" }))
end

local function forget_mistral()
	greed.secrets.set("mistral", "")
	greed.secrets.set("vibe-login", "")
end

test("signing in with Vibe shows the link, waits, and keeps the key as the mistral key", function(t)
	local sent = serve({
		[VIBE] = { started() },
		[POLL] = {
			{ status = 200, body = { status = "pending" } },
			{ status = 200, body = { status = "completed", exchange_token = "x1" } },
		},
		[`{VIBE}/p1/exchange`] = { { status = 200, body = { api_key = "vibe-key" } } },
	})
	local shown: any, ok: string?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("vibe", function(started)
			shown = started
		end)
	end)
	assert(shown and shown.url == "https://console.mistral.ai/vibe/sign-in/p1", "it shows the link")
	assert(shown.code == nil and shown.minutes == 10, `{shown.code} {shown.minutes}`)
	assert(sent[1].kind == "json" and sent[1].body.code_challenge_method == "S256")
	t:wait(3000)
	assert(ok == nil and err == nil, "still waiting")
	t:wait(3000)
	assert(ok ~= nil, tostring(err))
	assert(sent[2].method == "GET" and sent[2].url == POLL and sent[3].method == "GET")
	local exchange = sent[4]
	assert(exchange.url == `{VIBE}/p1/exchange` and exchange.body.exchange_token == "x1")
	-- The verifier sent last is the one the challenge was made from.
	assert(#exchange.body.code_verifier >= 43, exchange.body.code_verifier)
	assert(challenge_of(exchange.body.code_verifier) == sent[1].body.code_challenge)
	assert(greed.secrets.get("mistral") == "vibe-key", "kept as the mistral key")
	assert(login.signed_in("vibe"))
	assert(models.key_state("mistral") == "signed in")
	models.roles.coding = { provider = "mistral", model = "mistral-vibe-cli-latest" }
	local line = table.concat(models.describe(), "\n")
	assert(string.find(line, "signed in (Vibe)", 1, true), line)
	models.roles.coding = nil
	forget_mistral()
end)

test("Vibe's sign-in pointing anywhere but Mistral's console is refused", function()
	local wrongs: { { [string]: any } } = {
		{ sign_in_url = "https://evil.example/vibe/sign-in/p1" },
		{ poll_url = "https://evil.example/api/vibe/sign-in/p1" },
		{ poll_url = "https://console.mistral.ai/api/../elsewhere" },
	}
	for _, wrong in wrongs do
		local sent = serve({ [VIBE] = { started(wrong) } })
		local shown = false
		local ok, err = login.sign_in("vibe", function()
			shown = true
		end)
		assert(ok == nil and string.find(tostring(err), "unexpected", 1, true), tostring(err))
		assert(not shown and #sent == 1, "nothing shown or polled")
	end
end)

test("Vibe's sign-in turned down, run out or failing says so", function(t)
	local cases: { { answer: { status: number, body: any }, says: string } } = {
		{ answer = { status = 200, body = { status = "denied" } }, says = "turned down" },
		{ answer = { status = 200, body = { status = "expired" } }, says = "ran out" },
		{ answer = { status = 410, body = {} }, says = "ran out" },
		{
			answer = { status = 200, body = { status = "error", message = "no plan" } },
			says = "no plan",
		},
	}
	for _, case in cases do
		serve({ [VIBE] = { started() }, [POLL] = { case.answer } })
		local ok: string?, err: string?
		greed.spawn(function()
			ok, err = login.sign_in("vibe", function() end)
		end)
		t:wait(3000)
		assert(ok == nil and string.find(tostring(err), case.says, 1, true), tostring(err))
		assert(not login.signed_in("vibe"))
	end
end)

test("a workspace that can't make Vibe keys says to pick another", function(t)
	serve({
		[VIBE] = { started() },
		[POLL] = { { status = 200, body = { status = "completed", exchange_token = "x" } } },
		[`{VIBE}/p1/exchange`] = { { status = 403, body = { error_code = 9004 } } },
	})
	local ok: string?, err: string?
	greed.spawn(function()
		ok, err = login.sign_in("vibe", function() end)
	end)
	t:wait(3000)
	assert(ok == nil and string.find(tostring(err), "another workspace", 1, true), tostring(err))
end)

test("logging out of Vibe forgets its key, but not a key you set yourself later", function(t)
	serve({
		[VIBE] = { started() },
		[POLL] = { { status = 200, body = { status = "completed", exchange_token = "x" } } },
		[`{VIBE}/p1/exchange`] = { { status = 200, body = { api_key = "vibe-key" } } },
	})
	greed.spawn(function()
		login.sign_in("vibe", function() end)
	end)
	t:wait(3000)
	assert(login.signed_in("vibe"))
	t:run("logout", { "vibe" })
	assert(not login.signed_in("vibe") and (greed.secrets.get("mistral") or "") == "", "forgotten")

	greed.secrets.set("vibe-login", "")
	serve({
		[VIBE] = { started() },
		[POLL] = { { status = 200, body = { status = "completed", exchange_token = "x" } } },
		[`{VIBE}/p1/exchange`] = { { status = 200, body = { api_key = "vibe-key" } } },
	})
	greed.spawn(function()
		login.sign_in("vibe", function() end)
	end)
	t:wait(3000)
	greed.secrets.set("mistral", "my-own")
	assert(not login.signed_in("vibe"), "a key set by hand isn't Vibe's")
	assert(models.key_state("mistral") == "key found")
	t:run("logout", { "vibe" })
	assert(greed.secrets.get("mistral") == "my-own", "your own key stays")
	forget_mistral()
end)

test(":login mistral offers Vibe's sign-in or a key", function(t)
	serve({
		[VIBE] = { started() },
		[POLL] = { { status = 200, body = { status = "completed", exchange_token = "x" } } },
		[`{VIBE}/p1/exchange`] = { { status = 200, body = { api_key = "vibe-key" } } },
	})
	t:buffer("|x")
	t:run("login", { "mistral" })
	t:type("vibe")
	t:keys("enter")
	t:wait(3000)
	assert(login.signed_in("vibe"), "signed in with Vibe")
	local said = t:messages()
	assert(string.find(said[#said] or "", "signed in to Vibe", 1, true), said[#said])
	forget_mistral()
end)

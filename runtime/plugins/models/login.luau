-- Signing in to a provider instead of using an API key, for plans that
-- come with an account, like Berget Code or Mistral's Vibe. `:login
-- berget` shows a link and a code to approve in your browser (on any
-- device); the tokens it gets are kept with greed.secrets and renewed when
-- they run out. `:login vibe` shows a link to sign in at Mistral, which
-- makes an API key for your plan, kept as the mistral key.
--
-- A provider signs in with `login = NAME`, naming one of `M.logins`: the
-- device sign-in of OAuth (RFC 8628) against its sign-in server, and how
-- to renew the tokens; or a sign-in of its own that ends with an API key.

local greed = require("@greed")
local core = require("@core")

--- What signing in gives: the token to send, the one to renew it with,
--- and when the first runs out, in seconds like `os.time()`.
export type Tokens = { access: string, refresh: string, expires: number }

--- What to show while signing in: where to go, the code to enter there if
--- there is one, and for how long it works.
export type Started = { url: string, code: string?, complete: string?, minutes: number }

--- How to sign in to a provider: its sign-in server's endpoints for the
--- device sign-in, the client and scopes to ask for, and how to renew
--- tokens (by default OAuth's refresh at `token_url`). A login that ends
--- with an API key instead names the secret it keeps the key as (`key`)
--- and gets it with `get_key`, which shows where to sign in and returns
--- the key, or nil and why. `doc` says what signing in is for.
export type Login = {
	title: string,
	doc: string?,
	device_url: string?,
	token_url: string?,
	client_id: string?,
	scope: string?,
	renew: ((tokens: Tokens) -> (Tokens?, string?))?,
	key: string?,
	get_key: ((show: (started: Started) -> ()) -> (string?, string?))?,
}

local M = {}

-- The status of a request and its answer as JSON, or nil and why.
local function send(request: greed.HttpRequest): (number?, any)
	local response, err = greed.http.request(request)
	if response == nil then
		return nil, err
	end
	local ok, decoded = pcall(greed.json.decode, response.body)
	-- Anything but a JSON object reads as an empty one, so fields are nil.
	return response.status, if ok and type(decoded) == "table" then decoded else {}
end

--- Sends a POST with `body` (form or JSON, as `kind` says) and returns the
--- status and the answer as JSON, or nil and why. Tests replace it.
function M.post(url: string, body: { [string]: string }, kind: "form" | "json"): (number?, any)
	local encoded, content_type
	if kind == "json" then
		encoded, content_type = greed.json.encode(body), "application/json"
	else
		local pairs_ = {}
		for key, value in body do
			local escaped = string.gsub(value, "[^%w%-%._~]", function(c: string): string
				return string.format("%%%02X", string.byte(c))
			end)
			table.insert(pairs_, `{key}={escaped}`)
		end
		table.sort(pairs_)
		encoded, content_type = table.concat(pairs_, "&"), "application/x-www-form-urlencoded"
	end
	return send({
		url = url,
		method = "POST",
		headers = { ["content-type"] = content_type },
		body = encoded,
		timeout = 30000,
	})
end

--- Sends a GET and returns the status and the answer as JSON, or nil and
--- why. Tests replace it.
function M.get(url: string): (number?, any)
	return send({ url = url, method = "GET", timeout = 30000 })
end

-- Tokens from a token endpoint's answer, keeping `refresh` when it sends
-- no new one.
local function tokens_from(answer: any, access: string, refresh: string?): Tokens?
	if type(answer[access]) ~= "string" or type(answer.expires_in) ~= "number" then
		return nil
	end
	local new_refresh = if type(answer.refresh_token) == "string"
		then answer.refresh_token
		else refresh
	if new_refresh == nil then
		return nil
	end
	return {
		access = answer[access],
		refresh = new_refresh,
		expires = os.time() + answer.expires_in,
	}
end

-- Renewed tokens from the status and answer of a POST to renew them, or
-- nil and why. `access` names the field the token comes in.
local function renewed_from(
	title: string,
	status: number?,
	answer: any,
	access: string,
	refresh: string
): (Tokens?, string?)
	if status == nil then
		return nil, `can't reach {title}: {answer}`
	elseif status >= 300 then
		return nil, `{title} said {status}: {answer.error_description or answer.error or "no"}`
	end
	local renewed = tokens_from(answer, access, refresh)
	if renewed == nil then
		return nil, `{title}'s answer had no token`
	end
	return renewed, nil
end

local BERGET_AUTH = "https://auth.berget.ai/realms/berget/protocol/openid-connect"

-- Mistral's Vibe sign-in, as the `vibe` CLI does it: start a sign-in with
-- a PKCE challenge, send you to its page, poll until you've signed in,
-- then trade what that gives (with the verifier) for an API key, made for
-- the plan of the workspace you picked.
local VIBE_CONSOLE = "https://console.mistral.ai"
local VIBE_API = `{VIBE_CONSOLE}/api`

-- Whether `url` is under `base`, with nothing in its path (`..`, escapes)
-- that could lead out of it.
local function under(url: any, base: string): boolean
	if type(url) ~= "string" or string.sub(url, 1, #base + 1) ~= `{base}/` then
		return false
	end
	local path = string.match(url, "^[^?#]*") or url
	return string.find(path, "..", 1, true) == nil and string.find(path, "%", 1, true) == nil
end

-- PKCE's S256 challenge for `verifier`: its SHA-256 in unpadded base64url.
local function challenge_of(verifier: string): string
	local raw = string.gsub(greed.hash.sha256(verifier), "%x%x", function(byte: string): string
		return string.char(tonumber(byte, 16) :: number)
	end)
	local encoded = string.gsub(greed.base64.encode(raw), "=+$", "")
	return (string.gsub(encoded, "[+/]", { ["+"] = "-", ["/"] = "_" }))
end

local function vibe_key(show: (started: Started) -> ()): (string?, string?)
	local verifier = greed.hash.random(32)
	local status, started = M.post(
		`{VIBE_API}/vibe/sign-in`,
		{ code_challenge = challenge_of(verifier), code_challenge_method = "S256" },
		"json"
	)
	if status == nil then
		return nil, `can't reach Mistral: {started}`
	elseif status >= 300 or type(started.process_id) ~= "string" then
		return nil, `Mistral said {status}: {started.message or started.detail or "no"}`
	elseif
		not under(started.sign_in_url, VIBE_CONSOLE) or not under(started.poll_url, VIBE_API)
	then
		return nil, "Mistral's sign-in sent an unexpected address"
	end
	local deadline = (
		if type(started.expires_at) == "string" then core.time.iso(started.expires_at) else nil
	) or os.time() + 600
	show({ url = started.sign_in_url, minutes = math.round((deadline - os.time()) / 60) })
	local failures = 0
	while os.time() < deadline do
		greed.sleep(3000)
		local polled, answer = M.get(started.poll_url)
		if polled == 410 or (polled and polled < 300 and answer.status == "expired") then
			return nil, "the sign-in ran out; :login again"
		elseif polled == nil or polled >= 300 then
			-- The network or a gateway's error page, tried a few times.
			failures += 1
			if failures >= 3 then
				local why = if polled then `it said {polled}` else answer
				return nil, `can't ask Mistral how the sign-in went: {why}`
			end
		elseif answer.status == "completed" and type(answer.exchange_token) == "string" then
			local traded, exchanged = M.post(
				`{VIBE_API}/vibe/sign-in/{started.process_id}/exchange`,
				{ exchange_token = answer.exchange_token, code_verifier = verifier },
				"json"
			)
			if traded == 403 and exchanged.error_code == 9004 then
				return nil,
					"this workspace can't make Vibe keys; sign in again and pick another workspace"
			elseif traded == nil or traded >= 300 or type(exchanged.api_key) ~= "string" then
				return nil, `Mistral gave no API key: {if traded then traded else exchanged}`
			end
			return exchanged.api_key, nil
		elseif answer.status == "denied" then
			return nil, "signing in was turned down in the browser"
		elseif answer.status == "error" then
			return nil, `Mistral said: {answer.message or "the sign-in failed"}`
		elseif answer.status ~= "pending" then
			return nil, `Mistral's sign-in said {answer.status}`
		else
			failures = 0
		end
	end
	return nil, "the sign-in ran out; :login again"
end

M.logins = {
	berget = {
		title = "Berget Code",
		device_url = `{BERGET_AUTH}/auth/device`,
		token_url = `{BERGET_AUTH}/token`,
		client_id = "berget-code",
		scope = "openid email profile offline_access device-email-otp",
		-- Berget renews through its own API, which answers with `token`.
		renew = function(tokens: Tokens): (Tokens?, string?)
			local status, answer = M.post(
				"https://api.berget.ai/v1/auth/refresh",
				{ refresh_token = tokens.refresh },
				"json"
			)
			return renewed_from("Berget", status, answer, "token", tokens.refresh)
		end,
	},
	vibe = {
		title = "Vibe",
		doc = "uses your Le Chat Pro or Team plan's allowance",
		key = "mistral",
		get_key = vibe_key,
	},
} :: { [string]: Login }

-- Where `name`'s tokens are kept in greed.secrets.
local function secret_of(name: string): string
	return `{name}-login`
end

local function load(name: string): Tokens?
	local kept = greed.secrets.get(secret_of(name))
	if kept == nil or kept == "" then
		return nil
	end
	local ok, tokens = pcall(greed.json.decode, kept)
	return if ok and type(tokens) == "table" and tokens.refresh then tokens else nil
end

-- Keeps `name`'s tokens; returns where, or nil and why not.
local function save(name: string, tokens: Tokens): (string?, string?)
	return greed.secrets.set(secret_of(name), greed.json.encode(tokens))
end

-- The key a key login got, while the secret it's kept as still holds it:
-- `{name}-login` keeps the key's digest, so a key you set yourself later
-- isn't taken for the sign-in's.
local function signed_in_key(name: string, login: Login): string?
	local digest = greed.secrets.get(secret_of(name))
	local key = login.key and greed.secrets.get(login.key)
	if digest == nil or digest == "" or key == nil or key == "" then
		return nil
	end
	return if greed.hash.sha256(key) == digest then key else nil
end

--- The name of the key a sign-in to `name` sends, as the places a key
--- may go know it: the secret a key login keeps its key as, else
--- "NAME sign-in".
function M.kept_as(name: string): string
	local login = M.logins[name]
	return (login and login.key) or `{name} sign-in`
end

-- OAuth's own refresh, for logins that don't renew their own way.
local function refresh(login: Login, tokens: Tokens): (Tokens?, string?)
	if login.token_url == nil then
		return nil, `{login.title} has no way to renew a sign-in`
	end
	local status, answer = M.post(login.token_url, {
		grant_type = "refresh_token",
		client_id = login.client_id or "",
		refresh_token = tokens.refresh,
	}, "form")
	return renewed_from(login.title, status, answer, "access_token", tokens.refresh)
end

-- Tokens being read or renewed, by login, so requests at once renew once.
local renewing: { [string]: greed.Signal } = {}

-- Renew a minute before the token runs out.
local MARGIN = 60

--- The token to send for `name`, renewed first if it's about to run out.
--- Nil and why when you aren't signed in or renewing failed.
function M.token(name: string): (string?, string?)
	local login = M.logins[name]
	if login == nil then
		return nil, `there's no login called {name}`
	elseif login.key then
		local key = signed_in_key(name, login)
		if key == nil then
			return nil, `not signed in to {login.title}: :login {name}`
		end
		return key, nil
	end
	local waiting = renewing[name]
	if waiting then
		local result = waiting:wait()
		return result.access, result.why
	end
	-- Reading the tokens waits too, so the guard starts before it.
	local done = greed.signal()
	renewing[name] = done
	local ok, access, why = pcall(function(): (string?, string?)
		local tokens = load(name)
		if tokens == nil then
			return nil, `not signed in to {login.title}: :login {name}`
		elseif os.time() < tokens.expires - MARGIN then
			return tokens.access, nil
		end
		local renewed, err
		if login.renew then
			renewed, err = login.renew(tokens)
		else
			renewed, err = refresh(login, tokens)
		end
		if renewed == nil then
			return nil, `{err}; :login {name} to sign in again`
		end
		-- The old refresh token may be spent now, so failing to keep the new
		-- one means signing in again later; say so now.
		local kept, save_err = save(name, renewed)
		if not kept then
			greed.echo(`can't keep the renewed {login.title} sign-in: {save_err}`)
		end
		return renewed.access, nil
	end)
	if not ok then
		access, why = nil, tostring(access)
	end
	renewing[name] = nil
	done:send({ access = access, why = why })
	return access, why
end

--- Whether you're signed in to `name`: there are tokens kept for it, or
--- for a key login, the key it got is still kept.
function M.signed_in(name: string): boolean
	local login = M.logins[name]
	if login and login.key then
		return signed_in_key(name, login) ~= nil
	end
	return load(name) ~= nil
end

-- Signs in to a key login, keeping the key it gets and its digest.
local function sign_in_for_key(
	name: string,
	login: Login,
	get_key: (show: (started: Started) -> ()) -> (string?, string?),
	show: (started: Started) -> ()
): (string?, string?)
	local key, err = get_key(show)
	if key == nil then
		return nil, err
	end
	local where, unkept = greed.secrets.set(login.key :: string, key)
	if where == nil then
		return nil, unkept
	end
	return greed.secrets.set(secret_of(name), greed.hash.sha256(key))
end

--- Signs in to `name`: `show` gets the link (and code) to approve in a
--- browser, then this waits (polling as the server asks) until you've
--- approved, and keeps the tokens, or for a key login the key. Returns
--- where they were kept (greed.secrets.set's answer), or nil and why not.
function M.sign_in(name: string, show: (started: Started) -> ()): (string?, string?)
	local login = M.logins[name]
	if login == nil then
		return nil, `there's no login called {name}`
	elseif login.get_key and login.key then
		return sign_in_for_key(name, login, login.get_key, show)
	end
	local device_url, token_url, client_id = login.device_url, login.token_url, login.client_id
	if device_url == nil or token_url == nil or client_id == nil then
		return nil, `{login.title} has no way to sign in`
	end
	local status, device =
		M.post(device_url, { client_id = client_id, scope = login.scope or "" }, "form")
	if status == nil then
		return nil, `can't reach {login.title}: {device}`
	elseif status >= 300 or type(device.device_code) ~= "string" then
		return nil,
			`{login.title} said {status}: {device.error_description or device.error or "no"}`
	end
	show({
		url = device.verification_uri,
		code = device.user_code,
		complete = device.verification_uri_complete,
		minutes = math.round((device.expires_in or 600) / 60),
	})
	local interval = device.interval or 5
	local deadline = os.time() + (device.expires_in or 600)
	while os.time() < deadline do
		greed.sleep(interval * 1000)
		local polled, answer = M.post(token_url, {
			client_id = client_id,
			device_code = device.device_code,
			grant_type = "urn:ietf:params:oauth:grant-type:device_code",
		}, "form")
		-- A failed poll (the network, a gateway's error page) is tried again.
		if polled and answer then
			local tokens = tokens_from(answer, "access_token", nil)
			if tokens then
				return save(name, tokens)
			elseif answer.error == "slow_down" then
				interval = math.min(interval + 5, 30)
			elseif answer.error == "access_denied" then
				return nil, "signing in was turned down in the browser"
			elseif answer.error == "expired_token" then
				return nil, "the code ran out; :login again"
			elseif answer.error ~= "authorization_pending" then
				return nil,
					`{login.title} said: {answer.error_description or answer.error or polled}`
			end
		end
	end
	return nil, "the code ran out; :login again"
end

--- Forgets the tokens kept for `name`, or for a key login its key, unless
--- that's been replaced by one of your own since.
function M.sign_out(name: string)
	local login = M.logins[name]
	if login and login.key and signed_in_key(name, login) then
		greed.secrets.set(login.key, "")
	end
	greed.secrets.set(secret_of(name), "")
end

return M

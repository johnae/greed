-- Signing in to a provider instead of using an API key, for plans that
-- come with an account, like Berget Code. `:login berget` shows a link and
-- a code to approve in your browser (on any device); the tokens it gets
-- are kept with greed.secrets and renewed when they run out.
--
-- A provider signs in with `login = NAME`, naming one of `M.logins`: the
-- device sign-in of OAuth (RFC 8628) against its sign-in server, and how
-- to renew the tokens.

local greed = require("@greed")

--- What signing in gives: the token to send, the one to renew it with,
--- and when the first runs out, in seconds like `os.time()`.
export type Tokens = { access: string, refresh: string, expires: number }

--- How to sign in to a provider: its sign-in server's endpoints for the
--- device sign-in, the client and scopes to ask for, and how to renew
--- tokens (by default OAuth's refresh at `token_url`).
export type Login = {
	title: string,
	device_url: string,
	token_url: string,
	client_id: string,
	scope: string,
	renew: ((tokens: Tokens) -> (Tokens?, string?))?,
}

local M = {}

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
	local response, err = greed.http.request({
		url = url,
		method = "POST",
		headers = { ["content-type"] = content_type },
		body = encoded,
		timeout = 30000,
	})
	if response == nil then
		return nil, err
	end
	local ok, decoded = pcall(greed.json.decode, response.body)
	-- Anything but a JSON object reads as an empty one, so fields are nil.
	return response.status, if ok and type(decoded) == "table" then decoded else {}
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

local function save(name: string, tokens: Tokens): (boolean, string?)
	local kept, err = greed.secrets.set(secret_of(name), greed.json.encode(tokens))
	return kept ~= nil, err
end

-- OAuth's own refresh, for logins that don't renew their own way.
local function refresh(login: Login, tokens: Tokens): (Tokens?, string?)
	local status, answer = M.post(login.token_url, {
		grant_type = "refresh_token",
		client_id = login.client_id,
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

--- Whether there are tokens kept for `name`.
function M.signed_in(name: string): boolean
	return load(name) ~= nil
end

--- What to show while signing in: where to go and the code to enter there.
export type Started = { url: string, code: string, complete: string?, minutes: number }

--- Signs in to `name` with OAuth's device sign-in: `show` gets the link
--- and code to approve in a browser, then this waits (polling as the
--- server asks) until you've approved, and keeps the tokens. Returns true,
--- or false and why.
function M.sign_in(name: string, show: (started: Started) -> ()): (boolean, string?)
	local login = M.logins[name]
	if login == nil then
		return false, `there's no login called {name}`
	end
	local status, device =
		M.post(login.device_url, { client_id = login.client_id, scope = login.scope }, "form")
	if status == nil then
		return false, `can't reach {login.title}: {device}`
	elseif status >= 300 or type(device.device_code) ~= "string" then
		return false,
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
		local polled, answer = M.post(login.token_url, {
			client_id = login.client_id,
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
				return false, "signing in was turned down in the browser"
			elseif answer.error == "expired_token" then
				return false, "the code ran out; :login again"
			elseif answer.error ~= "authorization_pending" then
				return false,
					`{login.title} said: {answer.error_description or answer.error or polled}`
			end
		end
	end
	return false, "the code ran out; :login again"
end

--- Forgets the tokens kept for `name`.
function M.sign_out(name: string)
	greed.secrets.set(secret_of(name), "")
end

return M

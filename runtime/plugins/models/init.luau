-- Language models by role. Plugins ask for a role, like "fast" or
-- "reasoning", and your config says which provider and model plays it, so
-- no plugin hard-codes a provider and switching to a local model is one line.
--
--   :models   each role's provider and model, and whether its key is found
--
-- In your config:
--
--     local models = require("@models")
--     models.roles.fast = { provider = "ollama", model = "llama3.2" }
--     models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", secret = "work" }
--
-- Keys come from greed.secrets (`:secret-set anthropic`, or ANTHROPIC_API_KEY).

local greed = require("@greed")
local registry = require("@core").registry
local sse = require("@self/sse")
local turn = require("@self/turn")
local login = require("@self/login")

export type ToolSpec = turn.ToolSpec
export type Call = turn.Call
export type Said = turn.Said
export type Turn = turn.Turn
export type TurnRequest = turn.Request

--- Where a model is served: `kind` is "anthropic" or "openai" (any server
--- with OpenAI's chat completions API, like Ollama or vLLM), `secret` the
--- name of its key in greed.secrets, if it needs one. A provider you can
--- sign in to names its `login` (login.luau); once signed in, that's used
--- instead of the key.
export type Provider = { kind: string, url: string, secret: string?, login: string? }

--- Which provider and model play a role.
export type Role = { provider: string, model: string }

export type Message = { role: "user" | "assistant", content: string }

--- What to ask: the conversation so far, and optionally instructions and
--- how long the answer may be (in tokens).
export type Request = {
	messages: { Message },
	system: string?,
	max_tokens: number?,
	temperature: number?,
}

--- An answer arriving piece by piece. `next` waits for the next piece of
--- text and returns it, nil at the end, or nil and why it failed; `text` is
--- everything so far.
export type Stream = {
	next: (self: Stream) -> (string?, string?),
	text: string,
	close: (self: Stream) -> (),
}

local M = {}

M.providers = {
	anthropic = { kind = "anthropic", url = "https://api.anthropic.com", secret = "anthropic" },
	openai = { kind = "openai", url = "https://api.openai.com/v1", secret = "openai" },
	ollama = { kind = "openai", url = "http://localhost:11434/v1" },
	berget = {
		kind = "openai",
		url = "https://api.berget.ai/v1",
		secret = "berget",
		login = "berget",
	},
} :: { [string]: Provider? }

M.roles = {
	fast = { provider = "anthropic", model = "claude-haiku-4-5-20251001" },
	reasoning = { provider = "anthropic", model = "claude-opus-5-5" },
	["local"] = { provider = "ollama", model = "llama3.2" },
} :: { [string]: Role? }

--- Adds or replaces the provider `name`, as your config can by setting
--- `providers[name]`. It goes when the plugin that added it does.
function M.provider(name: string, provider: Provider)
	greed.plugin.tie(registry.set(M.providers, name, provider))
end

--- Makes `role` played by `spec`, as your config can by setting
--- `roles[role]`. It goes when the plugin that set it does.
function M.role(role: string, spec: Role)
	greed.plugin.tie(registry.set(M.roles, role, spec))
end

-- How long an answer may be when the request doesn't say.
local MAX_TOKENS = 4096

--- The provider and model playing `role`, or why there are none.
function M.resolve(role: string): (Role?, Provider?, string?)
	local chosen = M.roles[role]
	if chosen == nil then
		return nil, nil, `no model plays the role "{role}"; set models.roles.{role} in your config`
	end
	local provider = M.providers[chosen.provider]
	if provider == nil then
		return nil,
			nil,
			`the role "{role}" uses the provider "{chosen.provider}", which isn't set up`
	end
	return chosen, provider, nil
end

-- The request to send, as the provider's API wants it.
local function http_request(
	provider: Provider,
	model: string,
	request: Request,
	key: string?
): greed.HttpRequest
	local headers: { [string]: string } = { ["content-type"] = "application/json" }
	local body: { [string]: any } = {
		model = model,
		messages = request.messages,
		max_tokens = request.max_tokens or MAX_TOKENS,
		temperature = request.temperature,
		stream = true,
	}
	if provider.kind == "anthropic" then
		headers["anthropic-version"] = "2023-06-01"
		if key then
			headers["x-api-key"] = key
		end
		body.system = request.system
		return {
			url = provider.url .. "/v1/messages",
			headers = headers,
			body = greed.json.encode(body),
		}
	end
	if key then
		headers.authorization = `Bearer {key}`
	end
	if request.system then
		local messages: { any } = { { role = "system", content = request.system } }
		for _, message in request.messages do
			table.insert(messages, message)
		end
		body.messages = messages
	end
	return {
		url = provider.url .. "/chat/completions",
		headers = headers,
		body = greed.json.encode(body),
	}
end

-- The text an event carries, whether the answer is done, and an error if
-- it reports one.
local function read_event(kind: string, event: sse.Event): (string?, boolean, string?)
	if event.data == "[DONE]" then
		return nil, true, nil
	end
	local decoded = greed.json.decode(event.data)
	if type(decoded) ~= "table" then
		return nil, false, nil
	end
	if decoded.error then
		local err = decoded.error
		return nil,
			true,
			if type(err) == "table" then err.message or greed.json.encode(err) else tostring(err)
	end
	if kind == "anthropic" then
		if decoded.type == "content_block_delta" and decoded.delta then
			return decoded.delta.text, false, nil
		end
		return nil, decoded.type == "message_stop", nil
	end
	local choice = decoded.choices and decoded.choices[1]
	local text = choice and choice.delta and choice.delta.content
	return if type(text) == "string" then text else nil, false, nil
end

-- Why a request the server refused failed, from its body.
local function refusal(status: number, body: string): string
	local decoded = greed.json.decode(body)
	local err = type(decoded) == "table" and decoded.error
	local message = if type(err) == "table"
		then err.message
		elseif type(err) == "string" then err
		else nil
	return `the model's server said {status}: {message or string.sub(body, 1, 200)}`
end

-- Where keys go. Any plugin can add a provider, so a key goes only to an
-- address you let it go to: the built-in providers' keys to their own
-- servers, and others once you've said yes, asked the first time. Your
-- answers are kept with the secrets, by key and address, where only a
-- plugin allowed that secret could change them.
local KNOWN: { [string]: string } = {
	anthropic = "https://api.anthropic.com",
	openai = "https://api.openai.com",
	berget = "https://api.berget.ai",
	["berget sign-in"] = "https://api.berget.ai",
}

local APPROVALS = "models-key-addresses"

-- What you said yes to, read the first time a key goes somewhere new.
local approvals: { [string]: { [string]: boolean } }? = nil

local function load_approvals(): { [string]: { [string]: boolean } }
	local loaded: { [string]: { [string]: boolean } } = {}
	local ok, saved = pcall(greed.json.decode, greed.secrets.get(APPROVALS) or "{}")
	for key, origins in (if ok and type(saved) == "table" then saved else {}) :: { [string]: any } do
		loaded[key] = {}
		for _, origin in origins do
			loaded[key][origin] = true
		end
	end
	return loaded
end

-- Whether the key called `name` may go to `url`, asking you the first time
-- for an address it isn't known to go to. Nil and why when it may not.
local function may_send(name: string, url: string): string?
	local origin = string.lower(string.match(url, "^%a[%w+.-]*://[^/?#]+") or url)
	if KNOWN[name] == origin then
		return nil
	end
	local known = approvals or load_approvals()
	approvals = known
	if known[name] and known[name][origin] then
		return nil
	end
	greed.echo(`send your {name} key to {origin}? y yes, from now on; n no`)
	local answer = greed.next_key()
	greed.echo("")
	if answer ~= "y" then
		return `you didn't let your {name} key go to {origin}`
	end
	known[name] = known[name] or {}
	known[name][origin] = true
	local out: { [string]: { string } } = {}
	for key, origins in known do
		out[key] = {}
		for address in origins do
			table.insert(out[key], address)
		end
	end
	greed.secrets.set(APPROVALS, greed.json.encode(out))
	return nil
end

-- The role's model and provider, and its key if it needs one. Callers vouch
-- for it (greed.vouch): plugins asking a model never see the key, and it
-- only goes where `may_send` lets it.
local function connect(role: string): (Role?, Provider?, string?, string?)
	local chosen, provider, why = M.resolve(role)
	if chosen == nil or provider == nil then
		return nil, nil, nil, why
	end
	local key: string?, name: string? = nil, nil
	if provider.login and login.signed_in(provider.login) then
		local token, err = login.token(provider.login)
		if token == nil then
			return nil, nil, nil, err
		end
		key, name = token, `{provider.login} sign-in`
	elseif provider.secret then
		key, name = greed.secrets.get(provider.secret), provider.secret
		if key == nil then
			return nil,
				nil,
				nil,
				`no key for {chosen.provider}: :secret-set {provider.secret}, or set it in the environment`
		end
	end
	local refused = name and may_send(name, provider.url)
	if refused then
		return nil, nil, nil, refused
	end
	return chosen, provider, key, nil
end

-- Sends `request` and waits for the answer to start, or says why it won't.
local function open(chosen: Role, request: greed.HttpRequest): (greed.HttpStream?, string?)
	local response, err = greed.http.stream(request)
	if response == nil then
		return nil, `can't reach {chosen.provider}: {err}`
	end
	if response.status >= 300 then
		local body = {}
		while true do
			local piece = response:read()
			if piece == nil then
				break
			end
			table.insert(body, piece)
		end
		return nil, refusal(response.status, table.concat(body))
	end
	return response, nil
end

--- Asks the model playing `role`, and returns the answer as it arrives.
--- Waits for the server to start answering. Works in commands, event
--- handlers and greed.spawn.
function M.stream(role: string, request: Request): (Stream?, string?)
	local chosen, provider, key, why = greed.vouch(connect, role)
	if chosen == nil or provider == nil then
		return nil, why
	end
	local response, err =
		greed.vouch(open, chosen, http_request(provider, chosen.model, request, key))
	if response == nil then
		return nil, err
	end
	local pending: { string } = {}
	local buffered = ""
	local done = false
	local stream: Stream
	stream = {
		text = "",
		next = function(_: Stream): (string?, string?)
			while #pending == 0 and not done do
				local piece, failed = response:read()
				if piece == nil then
					done = true
					if failed then
						return nil, failed
					end
					break
				end
				local events
				events, buffered = sse.parse(buffered .. piece)
				for _, event in events do
					local text, finished, problem = read_event(provider.kind, event)
					if problem then
						done = true
						response:close()
						return nil, problem
					end
					if text and text ~= "" then
						table.insert(pending, text)
					end
					if finished then
						done = true
						response:close()
					end
				end
			end
			local text = table.remove(pending, 1)
			if text then
				stream.text ..= text
			end
			return text, nil
		end,
		close = function(_: Stream): ()
			done = true
			response:close()
		end,
	}
	return stream, nil
end

--- One turn of a conversation with tools, by the model playing `role`:
--- `on_text` gets its text as it arrives, and the turn says what it said,
--- the tool calls it asked for and why it stopped. Waits like greed.sleep.
function M.turn(
	role: string,
	request: turn.Request,
	on_text: ((text: string) -> ())?
): (turn.Turn?, string?)
	local chosen, provider, key, why = greed.vouch(connect, role)
	if chosen == nil or provider == nil then
		return nil, why
	end
	local sent = http_request(provider, chosen.model, { messages = {} }, key)
	sent.body = greed.json.encode(turn.body(provider.kind, chosen.model, request, MAX_TOKENS))
	local response, err = greed.vouch(open, chosen, sent)
	if response == nil then
		return nil, err
	end
	local reader = turn.reader(provider.kind)
	local buffered = ""
	while true do
		local piece, failed = response:read()
		if piece == nil then
			if failed then
				return nil, failed
			end
			return reader.turn(), nil
		end
		local events
		events, buffered = sse.parse(buffered .. piece)
		for _, event in events do
			local text, finished, problem = reader.feed(event)
			if problem then
				response:close()
				return nil, problem
			end
			if text and on_text then
				on_text(text)
			end
			if finished then
				response:close()
				return reader.turn(), nil
			end
		end
	end
end

M.tools = turn

-- The logins as plugins see them: a new one can be added, but none taken
-- over or changed once it's there, so a plugin can't send another's
-- tokens somewhere else.
local logins_meta: any = {
	__index = login.logins,
	__newindex = function(_, name: string, spec: login.Login)
		if login.logins[name] then
			error(`there's a login called {name} already`, 2)
		end
		table.freeze(spec)
		local all: any = login.logins
		all[name] = spec
	end,
	__iter = function()
		return next, login.logins
	end,
}
local logins = table.freeze(setmetatable({}, logins_meta))
logins_meta.__metatable = false
table.freeze(logins_meta)
for _, known in login.logins do
	table.freeze(known)
end

--- Signing in to providers instead of using keys (login.luau): adding a
--- login, and posting to a sign-in server for a login's `renew`. Its
--- tokens stay inside this plugin.
M.login = table.freeze({
	logins = (logins :: any) :: { [string]: login.Login },
	post = login.post,
	signed_in = login.signed_in,
})

--- `answer` without the code fence a model may wrap it in, when it was
--- asked for plain text.
function M.unfenced(answer: string): string
	return string.match(answer, "^%s*```[%w_-]*\n(.-)\n?```%s*$") or answer
end

--- Asks the model playing `role` and waits for the whole answer.
function M.ask(role: string, request: Request): (string?, string?)
	local stream, err = M.stream(role, request)
	if stream == nil then
		return nil, err
	end
	while true do
		local piece, failed = stream:next()
		if failed then
			return nil, failed
		end
		if piece == nil then
			return stream.text, nil
		end
	end
end

-- The list of roles while it's shown.
local shown: greed.View? = nil

local function close()
	if shown then
		shown:close()
		shown = nil
	end
end

--- One line per role: its model and provider, and whether the key is found.
function M.describe(): { string }
	local names = {}
	for name in M.roles do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = {}
	for _, name in names do
		local chosen, provider, why = M.resolve(name)
		if chosen and provider then
			local key = "no key needed"
			if provider.login and login.signed_in(provider.login) then
				key = "signed in"
			elseif provider.secret then
				key = if greed.secrets.get(provider.secret)
					then "key found"
					else `no key: :secret-set {provider.secret}`
			end
			table.insert(
				lines,
				`{name}: {chosen.model} at {chosen.provider} ({provider.url}), {key}`
			)
		else
			table.insert(lines, `{name}: {why}`)
		end
	end
	return lines
end

greed.command({
	name = "models",
	doc = "Show which provider and model plays each role, and whether its key is found",
	run = function()
		close()
		local buffer =
			greed.create_buffer("models", table.concat(M.describe(), "\n"), { readonly = true })
		shown = greed.float(buffer, { title = "Models by role", width = "80%", height = "40%" })
	end,
})

greed.command({
	name = "models-close",
	doc = "Close the list of models",
	run = close,
})

-- The login named on the command line, or the only one there is.
local function login_named(ctx: greed.Context): string?
	local name = ctx.args[1]
	if name == nil then
		local names = {}
		for known in login.logins do
			table.insert(names, known)
		end
		if #names ~= 1 then
			table.sort(names)
			greed.echo(`sign in to which: {table.concat(names, ", ")}`)
			return nil
		end
		name = names[1]
	end
	if login.logins[name] == nil then
		greed.echo(`there's no login called {name}`)
		return nil
	end
	return name
end

greed.command({
	name = "login",
	doc = "Sign in to a provider whose plan comes with an account, like Berget Code, instead of using an API key",
	args = { { name = "provider", doc = "e.g. berget" } },
	run = function(ctx)
		local name = login_named(ctx)
		if name == nil then
			return
		end
		local title = login.logins[name].title
		local float: greed.View? = nil
		local ok, err = login.sign_in(name, function(started)
			local lines = {
				`Sign in to {title}: open`,
				"",
				`  {started.complete or started.url}`,
				"",
				`and enter the code {started.code} if it asks. It works for {started.minutes} minutes;`,
				"this closes once you've signed in.",
			}
			local buffer =
				greed.create_buffer("login", table.concat(lines, "\n"), { readonly = true })
			float = greed.float(buffer, { title = `Sign in to {title}`, width = "80%", height = 8 })
		end)
		if float then
			pcall(float.close, float)
		end
		greed.echo(if ok then `signed in to {title}` else `can't sign in to {title}: {err}`)
	end,
})

greed.command({
	name = "logout",
	doc = "Forget the sign-in kept for a provider",
	args = { { name = "provider", doc = "e.g. berget" } },
	run = function(ctx)
		local name = login_named(ctx)
		if name then
			login.sign_out(name)
			greed.echo(`signed out of {login.logins[name].title}`)
		end
	end,
})

greed.keymap.bind(
	{ mode = "normal", kind = "models" },
	{ q = "models-close", esc = "models-close" }
)

return M

-- Language models by role. Plugins ask for a role, like "fast" or
-- "reasoning", and your config says which provider and model plays it, so
-- no plugin hard-codes a provider and switching to a local model is one line.
--
--   :models   each role's provider and model and whether its key is found;
--             enter changes a role, k sets a key, l signs in
--
-- What you pick in :models (or the setup page) is kept in Greed's data
-- folder and read before your config, which has the last word.
--
-- In your config:
--
--     local models = require("@models")
--     models.roles.fast = { provider = "ollama", model = "llama3.2" }
--     models.providers.work = { kind = "openai", url = "https://llm.example.com/v1", secret = "work" }
--
-- Keys come from greed.secrets (`:models`, `:secret-set anthropic`, or
-- ANTHROPIC_API_KEY).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local registry = core.registry
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
--- instead of the key. `context` is how many tokens its models have room
--- for, when you'd rather say than have it guessed from the model's name,
--- `output` how long one of their answers may be, and `edits` how Greed's
--- agent has them edit files (see `M.edits`).
export type Provider = {
	kind: string,
	url: string,
	secret: string?,
	login: string?,
	context: number?,
	output: number?,
	edits: string?,
}

--- Which provider and model play a role, and optionally how many tokens
--- the model has room for (its context window) and may write in one answer,
--- whether it sees images, when its name doesn't tell (see `M.sees_images`),
--- and how Greed's agent has it edit files (see `M.edits`).
export type Role = {
	provider: string,
	model: string,
	context: number?,
	output: number?,
	edits: string?,
	images: boolean?,
}

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
	mistral = { kind = "openai", url = "https://api.mistral.ai/v1", secret = "mistral" },
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

-- The plugin that set each provider and role with `provider` and `role`,
-- by name, with what it set: a request runs within that plugin's limit
-- while it's still what's set, so one from a plugin without "net" sends
-- nothing.
type SetBy = { by: string?, value: any }
local provider_by: { [string]: SetBy } = {}
local role_by: { [string]: SetBy } = {}

--- Adds or replaces the provider `name`, as your config can by setting
--- `providers[name]`. It goes when the plugin that added it does.
function M.provider(name: string, provider: Provider)
	greed.plugin.tie(registry.set(M.providers, name, provider))
	greed.plugin.tie(
		registry.set(provider_by, name, { by = greed.plugin.caller(), value = provider })
	)
end

--- Makes `role` played by `spec`, as your config can by setting
--- `roles[role]`. It goes when the plugin that set it does.
function M.role(role: string, spec: Role)
	greed.plugin.tie(registry.set(M.roles, role, spec))
	greed.plugin.tie(registry.set(role_by, role, { by = greed.plugin.caller(), value = spec }))
end

-- The plugin that set `value` in `set_by` under `name`, if it's still set.
local function setter(set_by: { [string]: SetBy }, name: string, value: any): string?
	local entry = set_by[name]
	return if entry and rawequal(entry.value, value) then entry.by else nil
end

-- Runs `f` within the limits of the plugins that set role `role`'s model
-- and its provider, if plugins did.
local function as_set<A..., R...>(role: string, chosen: Role, f: (A...) -> R..., ...: A...): R...
	local played = M.playing(role)
	local by_role = setter(role_by, played, M.roles[played])
	local by_provider = setter(provider_by, chosen.provider, M.providers[chosen.provider])
	return greed.plugin.within(by_role, greed.plugin.within, by_provider, f, ...)
end

--- A role a plugin asks for that uses another role's model while none plays
--- it, like Greed's agent's `agent`, which uses `reasoning` until you set
--- one; `about` says who asks for it.
export type Fallback = { to: string, about: string }

--- The roles that fall back to another, by name; add with `fallback`.
M.fallbacks = {} :: { [string]: Fallback? }

--- Says that `role` uses `to`'s model while no model plays it, for :models
--- to show and `playing` to follow. It goes when the plugin that said it
--- does.
function M.fallback(role: string, to: string, about: string)
	greed.plugin.tie(registry.set(M.fallbacks, role, { to = to, about = about }))
end

--- The role whose model answers for `role`: itself when a model plays it,
--- else the one it falls back to, followed as far as it goes.
function M.playing(role: string): string
	local seen: { [string]: boolean } = {}
	while M.roles[role] == nil and M.fallbacks[role] and not seen[role] do
		seen[role] = true
		role = (M.fallbacks[role] :: Fallback).to
	end
	return role
end

-- The roles as Greed sets them, before your config: built in, or chosen
-- in :models or the setup page. Another table in a role's place means
-- your config (or a plugin) set it.
local own: { [string]: Role } = {}
for name, role in M.roles do
	own[name] = role :: Role
end

--- Whether `role` is as Greed set it (built in, or chosen in :models or
--- the setup page) rather than set by your config or a plugin.
function M.is_own(role: string): boolean
	local now = M.roles[role]
	return now == nil or own[role] == now
end

-- Where the roles chosen in :models and the setup page are kept.
local function chosen_path(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/models.json`
end

-- What's kept at `path`, or an empty table when there's nothing readable.
local function read_chosen(path: string?): { [string]: any }
	local text = path and greed.fs.read(path)
	local ok, saved = pcall(greed.json.decode, text or "{}")
	return if ok and type(saved) == "table" then saved else {}
end

-- The roles chosen before, read as the plugin loads: your config, which
-- runs after, still has the last word.
do
	local saved = read_chosen(chosen_path())
	local roles = if type(saved.roles) == "table" then saved.roles else {}
	for name, role in roles :: { [string]: any } do
		if
			type(role) == "table"
			and type(role.provider) == "string"
			and type(role.model) == "string"
		then
			local chosen: Role = { provider = role.provider, model = role.model }
			M.roles[name] = chosen
			own[name] = chosen
		end
	end
end

--- Has `role` played by `model` at `provider` from now on, kept in Greed's
--- data folder for next time (your config's own settings still come
--- first). Returns why not, if it can't keep it.
function M.choose(role: string, provider: string, model: string): string?
	local chosen: Role = { provider = provider, model = model }
	M.roles[role] = chosen
	own[role] = chosen
	local path = chosen_path()
	if path == nil then
		return "there's no data folder to keep it in"
	end
	local out = read_chosen(path)
	out.roles = if type(out.roles) == "table" then out.roles else {}
	out.roles[role] = { provider = provider, model = model }
	local written, err = greed.fs.write(path, greed.json.encode(out))
	return if written then nil else err
end

--- The models the `fast` and `reasoning` roles get when you pick a
--- provider in :models or the setup page, by provider.
M.presets = {
	anthropic = { fast = "claude-haiku-4-5-20251001", reasoning = "claude-opus-5-5" },
	openai = { fast = "gpt-5-mini", reasoning = "gpt-5" },
	berget = { fast = "meta-llama/Llama-3.3-70B-Instruct", reasoning = "openai/gpt-oss-120b" },
	mistral = { fast = "mistral-small-latest", reasoning = "mistral-large-4" },
	ollama = { fast = "llama3.2", reasoning = "llama3.2" },
} :: { [string]: { fast: string, reasoning: string }? }

-- How long an answer may be when the request doesn't say.
local MAX_TOKENS = 4096

--- The provider and model playing `role`, or why there are none. Copies:
--- change them with `provider` and `role`.
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
	return table.clone(chosen), table.clone(provider), nil
end

-- Context windows of models known by name: the first pattern found in the
-- model's name (lowercased) says.
local WINDOWS: { { pattern: string, tokens: number } } = {
	{ pattern = "claude", tokens = 200000 },
	{ pattern = "gpt%-4%.1", tokens = 1047576 },
	{ pattern = "gpt%-5", tokens = 400000 },
	{ pattern = "gpt%-4o", tokens = 128000 },
	{ pattern = "gpt%-oss", tokens = 131072 },
	{ pattern = "^o[134]", tokens = 200000 },
	{ pattern = "llama%-?3%.[123]", tokens = 131072 },
	{ pattern = "mistral%-small", tokens = 131072 },
	{ pattern = "mistral%-large%-4", tokens = 1048576 },
	{ pattern = "devstral", tokens = 131072 },
	{ pattern = "glm%-4%.[6-9]", tokens = 200000 },
	{ pattern = "glm%-4%.5", tokens = 131072 },
	{ pattern = "qwen3%-coder", tokens = 262144 },
	{ pattern = "deepseek", tokens = 131072 },
	{ pattern = "gemma%-?3", tokens = 131072 },
	{ pattern = "kimi%-k2", tokens = 131072 },
	{ pattern = "kimi%-k3", tokens = 1048576 },
}

--- What a model of unknown size is taken to have room for, in tokens.
M.WINDOW = 32000

--- How many tokens the model playing `role` has room for: the role's
--- `context`, its provider's, what's known of the model by name, or else
--- `WINDOW`. The second result says whether it's known rather than assumed.
function M.window(role: string): (number, boolean)
	local chosen, provider = M.resolve(role)
	if chosen == nil then
		return M.WINDOW, false
	elseif chosen.context then
		return chosen.context, true
	elseif provider and provider.context then
		return provider.context, true
	end
	local name = string.lower(chosen.model)
	for _, known in WINDOWS do
		if string.find(name, known.pattern) then
			return known.tokens, true
		end
	end
	return M.WINDOW, false
end

-- Models that see images, by a pattern in their name, lowercased.
local SEES = {
	"claude",
	"gpt%-4o",
	"gpt%-4%.1",
	"gpt%-5",
	"gemini",
	"gemma%-?3",
	"kimi%-k2%.[5-9]",
	"kimi%-k[3-9]",
	"kimi%-vl",
	"llama%-?4",
	"pixtral",
	"mistral%-small%-3%.[1-9]",
	"mistral%-medium",
	"mistral%-large%-[4-9]",
	"qwen[%d.]*%-vl",
	"glm%-4%.[5-9]v",
	"llava",
	"vision",
}

--- Whether the model playing `role` sees images: the role's `images`, or
--- else what's known of the model by name.
function M.sees_images(role: string): boolean
	local chosen = M.resolve(role)
	if chosen == nil then
		return false
	elseif chosen.images ~= nil then
		return chosen.images
	end
	local name = string.lower(chosen.model)
	for _, pattern in SEES do
		if string.find(name, pattern) then
			return true
		end
	end
	return false
end

-- The longest answer asked for when nothing says: enough to write a file
-- of a few hundred lines in one tool call, and within what models allow.
local OUTPUT = 32000

--- How many tokens the model playing `role` may write in one turn: the
--- role's `output`, its provider's, or else `OUTPUT`, never more than a
--- quarter of its context window, leaving the rest for the conversation.
function M.output(role: string): number
	local chosen, provider = M.resolve(role)
	local said = (chosen and chosen.output) or (provider and provider.output)
	if said then
		return said
	end
	return math.min(OUTPUT, M.window(role) // 4)
end

--- The ways Greed's agent can have a model edit files: "replace", old
--- text to new, which models trained on it do best with, and "hashline",
--- lines named by their number and a short hash of their text, which helps
--- models that miscopy text.
M.EDITS = { "replace", "hashline" }

--- How Greed's agent has the model playing `role` edit files: the role's
--- `edits`, its provider's, or "replace".
function M.edits(role: string): string
	local chosen, provider = M.resolve(M.playing(role))
	local function known(said: string?): string?
		return if said and table.find(M.EDITS, said) then said else nil
	end
	return known(chosen and chosen.edits) or known(provider and provider.edits) or "replace"
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
	mistral = "https://api.mistral.ai",
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
	-- The whole word, so keys pressed while typing something else don't
	-- answer it.
	local answer =
		core.prompt.ask(`Send your {name} key to {origin} from now on? Type yes to allow it`)
	if answer == nil or string.lower(string.match(answer, "^%s*(.-)%s*$") or "") ~= "yes" then
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

--- What every feature says when the provider `name` has no key: the
--- variable that sets one, and how to add one instead. With `unreachable`,
--- why greed.secrets couldn't ask the system keyring, which may have it.
function M.no_key(name: string, unreachable: string?): string
	local provider = M.providers[name]
	local secret = (provider and provider.secret) or name
	local variable = greed.secrets.variable(secret)
	if unreachable then
		local add = if provider and provider.login
			then `:login {provider.login}`
			else "adding one in :models"
		return `no API key for {name}: {unreachable}; {add} saves it in Greed's own `
			.. `secrets file instead, or set {variable}`
	end
	local sign_in = if provider and provider.login then `:login {provider.login}, ` else ""
	return `no API key for {name}: {sign_in}set {variable}, or add one in :models`
end

-- How the provider `name` stands for keys, the message saying it has none,
-- and why the keyring couldn't be asked, when it couldn't.
local function key_state(name: string): (string?, string?, string?)
	local provider = M.providers[name]
	if provider == nil then
		return nil, `the provider "{name}" isn't set up`, nil
	elseif provider.login and login.signed_in(provider.login) then
		return "signed in", nil, nil
	elseif provider.secret == nil then
		return "no key needed", nil, nil
	end
	local key, unreachable = greed.secrets.get(provider.secret)
	if key then
		return "key found", nil, nil
	end
	return nil, M.no_key(name, unreachable), unreachable
end

--- How the provider `name` stands for keys: "signed in", "key found" or
--- "no key needed", or nil and the message saying it has no key. Any
--- plugin may ask: it tells whether there's a key, never the key.
function M.key_state(name: string): (string?, string?)
	local state, missing = greed.vouch(key_state, name)
	return state, missing
end

--- Why the model for `role` can't be asked now, without asking it: no
--- model plays the role, its provider isn't set up or has no key. Nil
--- when nothing's missing as far as Greed can tell.
function M.check(role: string): string?
	local chosen, _, why = M.resolve(M.playing(role))
	if chosen == nil then
		return why
	end
	local _, missing = M.key_state(chosen.provider)
	return missing
end

-- Whether `provider` is an Ollama: the one built in, or one at its port.
local function is_ollama(name: string, provider: Provider): boolean
	return name == "ollama" or string.find(provider.url, ":11434", 1, true) ~= nil
end

local function ollama_models(): ({ string }?, string?)
	local ollama = M.providers.ollama
	if ollama == nil then
		return nil, "there's no ollama provider"
	end
	local base = string.gsub(ollama.url, "/v1/*$", "")
	local response = greed.http.request({ url = `{base}/api/tags`, timeout = 3000 })
	if response == nil or response.status >= 300 then
		return nil, `Ollama isn't answering at {base}: start it with \`ollama serve\``
	end
	local ok, decoded = pcall(greed.json.decode, response.body)
	local listed = if ok and type(decoded) == "table" then decoded.models else nil
	local names: { string } = {}
	if type(listed) == "table" then
		for _, model in listed :: { any } do
			if type(model) == "table" and type(model.name) == "string" then
				table.insert(names, (string.gsub(model.name, ":latest$", "")))
			end
		end
	end
	return names, nil
end

--- The models the Ollama provider has pulled, or nil and what to do when
--- it doesn't answer.
function M.ollama_models(): ({ string }?, string?)
	return greed.vouch(ollama_models)
end

-- What to do about `err` from a request to the role's Ollama, added to it.
local function ollama_hint(chosen: Role, err: string, status: number?): string
	if status == nil then
		return `{err}; is Ollama running? \`ollama serve\` starts it`
	elseif status == 404 then
		return `{err}; \`ollama pull {chosen.model}\` fetches the model`
	end
	return err
end

-- The role's model and provider, and its key if it needs one. Callers vouch
-- for it (greed.vouch): plugins asking a model never see the key, and it
-- only goes where `may_send` lets it.
local function connect(role: string): (Role?, Provider?, string?, string?)
	local chosen, provider, why = M.resolve(M.playing(role))
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
		local unreachable
		key, unreachable = greed.secrets.get(provider.secret)
		name = provider.secret
		if key == nil then
			return nil, nil, nil, M.no_key(chosen.provider, unreachable)
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
	local provider = M.providers[chosen.provider]
	local ollama = provider ~= nil and is_ollama(chosen.provider, provider)
	local response, err = greed.http.stream(request)
	if response == nil then
		local why = `can't reach {chosen.provider}: {err}`
		return nil, if ollama then ollama_hint(chosen, why, nil) else why
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
		local why = refusal(response.status, table.concat(body))
		return nil, if ollama then ollama_hint(chosen, why, response.status) else why
	end
	return response, nil
end

-- `open` as the plugins that set role `role`'s model and provider may, or
-- why not when they may not.
local function send(
	role: string,
	chosen: Role,
	request: greed.HttpRequest
): (greed.HttpStream?, string?)
	local ok, response, err = pcall(as_set, role, chosen, open, chosen, request)
	if not ok then
		return nil, tostring(response)
	end
	return response, err
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
		greed.vouch(send, role, chosen, http_request(provider, chosen.model, request, key))
	-- Newer models refuse a temperature; they're asked again without one.
	if
		response == nil
		and request.temperature
		and string.find(err or "", "temperature", 1, true)
	then
		local plain = table.clone(request)
		plain.temperature = nil
		response, err =
			greed.vouch(send, role, chosen, http_request(provider, chosen.model, plain, key))
	end
	if response == nil then
		return nil, err
	end
	local reply: greed.HttpStream = response
	local pending: { string } = {}
	local buffered = ""
	local done = false
	local stream: Stream
	stream = {
		text = "",
		next = function(_: Stream): (string?, string?)
			while #pending == 0 and not done do
				local piece, failed = reply:read()
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
						reply:close()
						return nil, problem
					end
					if text and text ~= "" then
						table.insert(pending, text)
					end
					if finished then
						done = true
						reply:close()
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
			reply:close()
		end,
	}
	return stream, nil
end

-- Tokens used, kept in the data folder as a file a day: requests and the
-- tokens read and written, by hour and model, as providers report them.
local function usage_path(day: string): string?
	local data = greed.fs.dirs().data
	return data and `{data}/usage/{day}.json`
end

--- Edits Greed's agent made one way, that worked and that failed.
export type Tally = { ok: number, failed: number }

--- What was used on `day` ("2026-10-09"): `{ [hour .. " " .. model] = { requests,
--- input, output, cached, edits } }`, models as "provider/model"; `cached` is the
--- part of `input` read from the provider's cache, and `edits` how Greed's
--- agent's edits went, by how they were made (`M.EDITS`).
export type Used = {
	requests: number,
	input: number,
	output: number,
	cached: number?,
	edits: { [string]: Tally }?,
}
function M.usage(day: string): { [string]: Used }
	local path = usage_path(day)
	local text = if path then greed.fs.read(path) else nil
	local ok, kept = pcall(greed.json.decode, text or "{}")
	return if ok and type(kept) == "table" then kept else {}
end

-- Changes what `model` at `provider` used this hour as `change` says, and
-- keeps it.
local function record(provider: string, model: string, change: (used: Used) -> ())
	local day, hour = os.date("%Y-%m-%d"), os.date("%H")
	local path = usage_path(day)
	if path == nil then
		return
	end
	local kept = M.usage(day)
	local key = `{hour} {provider}/{model}`
	local used: Used = kept[key] or { requests = 0, input = 0, output = 0 }
	change(used)
	kept[key] = used
	greed.fs.write(path, greed.json.encode(kept))
end

--- Counts a request to `model` at `provider` that read `input` tokens,
--- `cached` of them from its cache, and wrote `output`, as each turn does.
function M.count(provider: string, model: string, input: number?, output: number?, cached: number?)
	record(provider, model, function(used: Used)
		used.requests += 1
		used.input += input or 0
		used.output += output or 0
		used.cached = (used.cached or 0) + (cached or 0)
	end)
end

local function count_edit(provider: string, model: string, how: string, ok: boolean)
	record(provider, model, function(used: Used)
		local edits: { [string]: Tally } = used.edits or {}
		local tally: Tally = edits[how] or { ok = 0, failed = 0 }
		if ok then
			tally.ok += 1
		else
			tally.failed += 1
		end
		edits[how] = tally
		used.edits = edits
	end)
end

--- Counts an edit Greed's agent had `model` at `provider` make, the way
--- `how` says (`M.EDITS`), and whether it worked. It's kept with what was
--- used, as this plugin keeps it, whoever counts.
function M.count_edit(provider: string, model: string, how: string, ok: boolean)
	greed.vouch(count_edit, provider, model, how, ok)
end

-- `n` tokens, short: 950, 12.3k, 4.56M.
local function short(n: number): string
	if n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(n)
end

-- What `used` read and wrote, in words: "4000 in (2500 cached), 70 out".
local function amounts(used: Used): string
	local cached = used.cached or 0
	local from_cache = if cached > 0 then ` ({short(cached)} cached)` else ""
	return `{used.requests} requests, {short(used.input)} in{from_cache}, {short(used.output)} out`
end

-- `used` added to `sum`.
local function add(sum: Used, used: Used)
	sum.requests += used.requests
	sum.input += used.input
	sum.output += used.output
	sum.cached = (sum.cached or 0) + (used.cached or 0)
	if used.edits then
		local edits: { [string]: Tally } = sum.edits or {}
		for how, tally in used.edits do
			local into: Tally = edits[how] or { ok = 0, failed = 0 }
			into.ok += tally.ok
			into.failed += tally.failed
			edits[how] = into
		end
		sum.edits = edits
	end
end

-- How `used`'s edits went, in words: "hashline 1 of 1, replace 1 of 2"
-- worked; nil when there were none.
local function edits_of(used: Used): string?
	local edits = used.edits
	if edits == nil then
		return nil
	end
	local parts = {}
	for how, tally in edits do
		table.insert(parts, `{how} {tally.ok} of {tally.ok + tally.failed}`)
	end
	table.sort(parts)
	return if #parts > 0 then table.concat(parts, ", ") else nil
end

--- What models were used for over the last `days` days (7 by default),
--- as lines to read: today by model, then each day's totals.
function M.usage_report(days: number?): { string }
	local lines = {}
	local today = M.usage(os.date("%Y-%m-%d"))
	local by_model: { [string]: Used } = {}
	for key, used in today do
		local model = string.match(key, "^%d+ (.+)$") or key
		local sum: Used = by_model[model] or { requests = 0, input = 0, output = 0 }
		add(sum, used)
		by_model[model] = sum
	end
	table.insert(lines, "Today")
	local models = {}
	for model in by_model do
		table.insert(models, model)
	end
	table.sort(models)
	if #models == 0 then
		table.insert(lines, "  nothing yet")
	end
	for _, model in models do
		table.insert(lines, `  {model}: {amounts(by_model[model])}`)
		local edits = edits_of(by_model[model])
		if edits then
			table.insert(lines, `    edits: {edits} worked`)
		end
	end
	table.insert(lines, "")
	table.insert(lines, "Each day")
	local now = os.time()
	for back = 0, (days or 7) - 1 do
		local day = os.date("%Y-%m-%d", now - back * 86400)
		local sum: Used = { requests = 0, input = 0, output = 0 }
		for _, used in M.usage(day) do
			add(sum, used)
		end
		if sum.requests > 0 then
			table.insert(lines, `  {day}: {amounts(sum)}`)
		end
	end
	return lines
end

greed.command({
	name = "usage",
	doc = "How many tokens the models were sent and wrote today and over the last week",
	run = function()
		core.floats.show_text("Usage", table.concat(M.usage_report(), "\n"), { kind = "usage" })
	end,
})

-- `request` with its images left out, for a model that doesn't see them,
-- as after switching to one once they were pasted. What you said already
-- tells where each image is saved.
local function unseen(request: turn.Request): turn.Request
	local said: { turn.Said } = {}
	for _, s in request.said do
		if s.images then
			s = table.clone(s)
			s.images = nil
			s.text =
				`{s.text or ""}\n[You can't see images, so they're left out; work with their files.]`
		end
		table.insert(said, s)
	end
	local out = table.clone(request)
	out.said = said
	return out
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
	if not M.sees_images(role) then
		request = unseen(request)
	end
	local sent = http_request(provider, chosen.model, { messages = {} }, key)
	sent.body = greed.json.encode(turn.body(provider.kind, chosen.model, request, M.output(role)))
	local response, err = greed.vouch(send, role, chosen, sent)
	if response == nil then
		return nil, err
	end
	local reader = turn.reader(provider.kind)
	local buffered = ""
	-- The turn as it ended, its tokens counted.
	local function ended(): turn.Turn
		local done = reader.turn()
		greed.vouch(M.count, chosen.provider, chosen.model, done.input, done.output, done.cached)
		return done
	end
	while true do
		local piece, failed = response:read()
		if piece == nil then
			if failed then
				return nil, failed
			end
			return ended(), nil
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
				return ended(), nil
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

-- Whether `provider` has a key, as the :models page says it.
local function key_text(name: string, provider: Provider): string
	local state, _, unreachable = greed.vouch(key_state, name)
	if state then
		return state
	end
	local sign_in = if provider.login then "l signs in, " else ""
	local keeps = if unreachable then " to Greed's own secrets file" else ""
	local why = if unreachable then ` ({unreachable})` else ""
	local variable = greed.secrets.variable(provider.secret or name)
	return `no API key{why}: {sign_in}k adds one{keeps}, or set {variable}`
end

-- What the :models page says of `name`, which a model plays.
local function played(name: string): string
	local chosen, provider, why = M.resolve(name)
	if chosen == nil or provider == nil then
		return why or "not set up"
	end
	local key = key_text(chosen.provider, provider)
	return `{chosen.model} at {chosen.provider} ({provider.url}), {key}`
end

type Row = { role: string, text: string }

-- A row per role, sorted: those a model plays, and those that fall back
-- to another's.
local function rows(): { Row }
	local names: { string } = {}
	for name in M.roles do
		table.insert(names, name)
	end
	for name in M.fallbacks do
		if M.roles[name] == nil then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out: { Row } = {}
	for _, name in names do
		local fallback = M.fallbacks[name]
		local text
		if M.roles[name] then
			text = `{name}: {played(name)}`
			if not M.is_own(name) then
				text ..= " (set in your config)"
			end
		elseif fallback then
			local playing = M.playing(name)
			text = `{name}: for {fallback.about}; none set, so it uses {playing}: {played(playing)}`
		else
			continue
		end
		table.insert(out, { role = name, text = text })
	end
	return out
end

--- One line per role: its model and provider and whether its key is
--- found, or, for a role that falls back to another, whose model it uses.
function M.describe(): { string }
	local lines = {}
	for _, row in rows() do
		table.insert(lines, row.text)
	end
	return lines
end

--- Asks you for the API key of the provider `name` and keeps it with your
--- secrets. Returns what happened, to tell you. Any plugin may ask: what
--- you type goes to your secrets, never to the plugin.
function M.ask_key(name: string): string
	local provider = M.providers[name]
	local secret = provider and provider.secret
	if provider == nil or secret == nil then
		return `{name} needs no key`
	end
	local key = core.prompt.ask(
		`API key for {name}, kept in the system keyring (or Greed's secrets file)`,
		nil,
		{ secret = true }
	)
	if key == nil or key == "" then
		return "no key given"
	end
	local where, err = greed.vouch(greed.secrets.set, secret, key)
	return if where then `kept the {name} key in {where}` else `can't keep the {name} key: {err}`
end

--- Has `role` use a model at the provider `name`, asking which: from those
--- Ollama has pulled, or typed, starting from the role's own or the
--- provider's preset. Then asks for a key if the provider needs one it
--- hasn't got. Returns what happened, to tell you.
function M.ask_model(role: string, name: string): string
	local provider = M.providers[name]
	if provider == nil then
		return `the provider "{name}" isn't set up`
	end
	local current = M.roles[role]
	local preset = M.presets[name]
	local start = if current and current.provider == name
		then current.model
		elseif preset then (if role == "fast" then preset.fast else preset.reasoning)
		else nil
	local model: string?
	if is_ollama(name, provider) then
		local pulled, why = M.ollama_models()
		if pulled and #pulled > 0 then
			local items = {}
			for _, found in pulled do
				table.insert(items, { label = found, value = found })
			end
			local item = picker.choose(`Model for {role}, of those Ollama has`, items)
			model = item and item.value
		else
			greed.echo(why or `Ollama has no models yet: \`ollama pull {start or "llama3.2"}\``)
			model = core.prompt.ask(`Model for {role} at {name}`, start)
		end
	else
		model = core.prompt.ask(`Model for {role} at {name}`, start)
	end
	if model == nil or model == "" then
		return "no model chosen"
	end
	local unkept = M.choose(role, name, model)
	local said = `{role} uses {model} at {name}`
		.. if unkept then ` for now (can't keep it: {unkept})` else ""
	if M.key_state(name) == nil then
		said ..= if provider.login
			then `; :login {provider.login} signs in`
			else "; " .. M.ask_key(name)
	end
	return said
end

--- Has the `fast` and `reasoning` roles use the provider `name`, with its
--- presets (for Ollama, the first model it has pulled), kept for next
--- time. Returns why not, if it can't keep the choice.
function M.use_provider(name: string): string?
	local preset = M.presets[name]
	if preset == nil then
		return `there are no models set for {name}; :models picks one`
	end
	local fast, reasoning = preset.fast, preset.reasoning
	if name == "ollama" then
		local pulled = M.ollama_models()
		if pulled and #pulled > 0 then
			fast, reasoning = pulled[1], pulled[1]
		end
	end
	return M.choose("fast", name, fast) or M.choose("reasoning", name, reasoning)
end

-- The :models page while it's open, and the role on each of its lines.
local page: { buffer: greed.Buffer, roles: { [number]: string } }? = nil

local PAGE_HINT = "enter changes the role's model · k sets its provider's API key · "
	.. "l signs in · q closes"

-- Writes the page again, as roles and keys change.
local function render()
	local shown = page
	if shown == nil or not shown.buffer:valid() then
		page = nil
		return
	end
	local lines = { "Models by role", PAGE_HINT, "" }
	shown.roles = {}
	for _, row in rows() do
		shown.roles[#lines] = row.role
		table.insert(lines, row.text)
	end
	local text = table.concat(lines, "\n")
	local buffer = shown.buffer
	if buffer:text() ~= text then
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
	end
	buffer:decorate("models", {
		{ from = 0, to = #lines[1], style = "markup.heading" },
		{ from = #lines[1] + 1, to = #lines[1] + 1 + #PAGE_HINT, style = "comment" },
	})
end

-- The role on the cursor's line of the page, or why there's none.
local function role_at(ctx: greed.Context): string?
	local shown = page
	if shown == nil or shown.buffer ~= ctx.buffer then
		return nil
	end
	local role = shown.roles[ctx.buffer:line_of(ctx.view:cursor())]
	if role == nil then
		greed.echo("move to a role's line first")
	end
	return role
end

-- The provider whose model plays `role` now, following its fallback.
local function provider_of(role: string): string?
	local chosen = M.roles[M.playing(role)]
	return chosen and chosen.provider
end

greed.command({
	name = "models",
	doc = "Show and change which model plays each role, set API keys and sign in",
	run = function()
		local shown = page
		if shown and shown.buffer:valid() then
			for _, view in shown.buffer:views() do
				view:focus()
				render()
				return
			end
		end
		local buffer = greed.create_buffer("models", "", { readonly = true })
		page = { buffer = buffer, roles = {} }
		render()
		buffer:set_keys({
			enter = "models-change",
			k = "models-key",
			l = "models-login",
			q = "models-close",
			esc = "models-close",
		})
		local view = greed.float(buffer, { title = "Models", width = "90%", height = "50%" })
		view:set_cursor(buffer:line_start(3))
	end,
})

greed.command({
	name = "models-change",
	doc = "On the :models page, pick the provider and model that play the role under the cursor",
	run = function(ctx)
		local role = role_at(ctx)
		if role == nil then
			return
		end
		local names: { string } = {}
		for name in M.providers do
			table.insert(names, name)
		end
		table.sort(names)
		local items = {}
		for _, name in names do
			local provider = M.providers[name] :: Provider
			table.insert(items, {
				label = `{name}  {provider.url}  {M.key_state(name) or "no key yet"}`,
				value = name,
			})
		end
		local item = picker.choose(`Provider for {role}`, items)
		if item then
			greed.echo(M.ask_model(role, item.value))
			render()
		end
	end,
})

greed.command({
	name = "models-key",
	doc = "On the :models page, set the API key of the provider of the role under the cursor",
	run = function(ctx)
		local role = role_at(ctx)
		local name = role and provider_of(role)
		if name then
			greed.echo(M.ask_key(name))
			render()
		end
	end,
})

greed.command({
	name = "models-login",
	doc = "On the :models page, sign in to the provider of the role under the cursor",
	run = function(ctx)
		local role = role_at(ctx)
		local name = role and provider_of(role)
		local provider = name and M.providers[name]
		if provider == nil then
			return
		elseif provider.login == nil then
			greed.echo(`{name} has no sign-in; k sets its API key`)
			return
		end
		greed.run("login", { args = { provider.login } })
		render()
	end,
})

greed.command({
	name = "models-close",
	doc = "Close the :models page",
	run = function(ctx)
		if page and page.buffer == ctx.buffer then
			ctx.view:close()
		end
	end,
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
	doc = "Sign in to a provider: with an account for those whose plan comes with one, like Berget Code, or else its API key",
	args = { { name = "provider", doc = "e.g. berget or mistral" } },
	run = function(ctx)
		-- A provider that only takes a key is signed in to with it.
		local wanted = ctx.args[1]
		local provider = wanted and M.providers[wanted]
		if wanted and provider and provider.login == nil and provider.secret then
			greed.echo(M.ask_key(wanted))
			return
		end
		local name = login_named(ctx)
		if name == nil then
			return
		end
		local title = login.logins[name].title
		local float: greed.View? = nil
		local kept, err = login.sign_in(name, function(started)
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
		greed.echo(
			if kept
				then `signed in to {title}, kept in {kept}`
				else `can't sign in to {title}: {err}`
		)
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

return M

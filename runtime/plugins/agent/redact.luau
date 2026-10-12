-- Secrets taken out of what a command printed before a model reads it:
-- private keys, cloud and API tokens, JSON Web Tokens, bearer tokens and
-- the values of variables named like secrets (`DB_PASSWORD=...`). What's
-- left says where one was, so the model knows something was there. It
-- catches the common shapes, not every secret; you see the output as it
-- is, in the shell.

local M = {}

local HIDDEN = "[secret hidden]"

-- Tokens known by their shape, as Luau patterns.
local TOKENS = {
	"A[KS]IA" .. string.rep("[%u%d]", 16),
	"gh[pousr]_%w+",
	"github_pat_[%w_]+",
	"glpat%-[%w_%-]+",
	"xox[abprs]%-[%w%-]+",
	"sk%-ant%-[%w_%-]+",
	"sk%-proj%-[%w_%-]+",
	"sk%-%w+",
	"eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+",
}

-- Words in a variable's or field's name that say its value is a secret.
local SECRET_NAMES =
	{ "password", "passwd", "secret", "token", "api_key", "apikey", "private_key", "credential" }

-- Whether `name` says its value is a secret.
local function secret_name(name: string): boolean
	local lower = string.lower(name)
	for _, word in SECRET_NAMES do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

local KEY_BEGIN = "%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-"
local KEY_END = "%-%-%-%-%-END [%u ]*PRIVATE KEY%-%-%-%-%-"

-- `text` with each private key, from its first line to its last, swapped
-- for `hide()`. Once a key has no last line no later one has either, so
-- this stops there; `BEGIN.-END` as one pattern looked for the end again
-- from each beginning.
local function private_keys(text: string, hide: () -> string): string
	local parts = {}
	local at = 1
	while true do
		local from, after = string.find(text, KEY_BEGIN, at)
		if from == nil or after == nil then
			break
		end
		local _, to = string.find(text, KEY_END, after + 1)
		if to == nil then
			break
		end
		table.insert(parts, string.sub(text, at, from - 1))
		table.insert(parts, hide())
		at = to + 1
	end
	table.insert(parts, string.sub(text, at))
	return table.concat(parts)
end

--- `text` with the secrets it holds hidden, and how many there were.
function M.redact(text: string): (string, number)
	local count = 0
	local function hide(): string
		count += 1
		return HIDDEN
	end
	text = private_keys(text, hide)
	for _, pattern in TOKENS do
		text = string.gsub(text, pattern, function(token: string): string
			-- Short matches of the loosest shapes are words, not tokens.
			return if #token >= 20 then hide() else token
		end)
	end
	-- `Bearer abc...`, as headers have it.
	text = string.gsub(text, "([Bb]earer%s+)([%w%._~%+/=%-]+)", function(...: string): string
		local lead, token = ...
		return if #token >= 12 then lead .. hide() else lead .. token
	end)
	-- `NAME=value`, `NAME: value` and `"name": "value"` with a name like a
	-- secret's. The frontier starts a name only where a run of name
	-- characters starts: tried from inside one too, a long run (a base64
	-- blob, a line of x's) took time growing with the square of its length.
	text = string.gsub(
		text,
		'("?)(%f[%w_%.%-][%w_%.%-]+)("?%s*[:=]%s*)("?)([^%s",}]+)',
		function(...: string): string
			local open, name, between, quote, value = ...
			if secret_name(name) and string.sub(value, 1, 7) ~= "[secret" and #value >= 4 then
				return open .. name .. between .. quote .. hide()
			end
			return open .. name .. between .. quote .. value
		end
	)
	return text, count
end

return M

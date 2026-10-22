-- Encrypted rooms, for the services that have them (Matrix): `:chat-recover`
-- unlocks the keys kept on the server with your recovery key, so older
-- messages decrypt; `:chat-encryption` says how an account stands and sets
-- a recovery key up where there's none; `:chat-verify` verifies this device
-- against another of yours by comparing emoji. Another device asking to
-- verify this one is asked about as it comes.

local greed = require("@greed")
local core = require("@core")
local backend = require("./backend")
local accounts = require("./accounts")

local M = {}

local ask = accounts.ask

-- Runs `f` with the one account that encrypts, or the one picked.
local function with_account(f: (key: string) -> ())
	accounts.with_account(
		accounts.keys("encryption"),
		"no account here has encrypted rooms (Matrix): :chat-login signs in",
		f
	)
end

--- How an account's encryption stands, in words, or nil when all is well.
function M.trouble(state: any): string?
	if state.verified then
		return nil
	elseif state.recovery == "enabled" or state.recovery == "incomplete" then
		return "this device isn't verified: :chat-recover with your recovery key, or :chat-verify"
	end
	return "this device isn't verified: :chat-verify with another of your devices"
end

-- Asks `question`: whether the answer was yes.
local function yes(question: string): boolean
	local answer = core.prompt.ask(question)
	return answer == "y" or answer == "yes"
end

-- Shows `lines` in a float, to read (and copy).
local function show(title: string, lines: { string }): greed.View
	local buffer = greed.create_buffer("chat-note", table.concat(lines, "\n"), { readonly = true })
	buffer:set_line_numbers(false)
	return greed.float(buffer, { title = title, width = "60%", height = #lines + 2 })
end

greed.command({
	name = "chat-recover",
	doc = "Unlock a Matrix account's keys with its recovery key, so older messages decrypt",
	run = function()
		with_account(function(key)
			local recovery = core.prompt.ask("Recovery key", nil, { secret = true })
			if recovery == nil or recovery == "" then
				return
			end
			local _, why = ask(key, "encryption.recover", { key = recovery })
			greed.echo(
				if why then `chat: {why}` else "unlocked: older messages decrypt as they're shown"
			)
		end)
	end,
})

greed.command({
	name = "chat-encryption",
	doc = "How a Matrix account's encryption stands; sets a recovery key up where there's none",
	run = function()
		with_account(function(key)
			local state, why = ask(key, "encryption.state")
			if state == nil then
				greed.echo(`chat: {why}`)
				return
			end
			if state.recovery == "disabled" then
				if not yes("No recovery key yet. Set one up now? (y/n; you'll write it down)") then
					return
				end
				local made, trouble = ask(key, "encryption.setup")
				if made == nil then
					greed.echo(`chat: {trouble}`)
					return
				end
				show("Your recovery key", {
					made.key,
					"",
					"Keep it somewhere safe, like a password manager. With it a new",
					"device reads your older encrypted messages: :chat-recover there.",
					"It isn't kept anywhere by Greed.",
				})
				return
			end
			greed.echo(
				M.trouble(state) or `{key}: this device is verified; recovery {state.recovery}`
			)
		end)
	end,
})

greed.command({
	name = "chat-verify",
	doc = "Verify this device against another of yours (a phone, Element) by comparing emoji",
	run = function()
		with_account(function(key)
			local started, why = ask(key, "verify.start")
			greed.echo(
				if started
					then "Asked your other devices: accept there, then compare the emoji"
					else `chat: {why}`
			)
		end)
	end,
})

--- The emoji to compare, as they're shown: each with its name.
function M.emoji_lines(emoji: { { string } }): { string }
	local symbols, names = {}, {}
	for _, one in emoji do
		table.insert(symbols, one[1])
		table.insert(names, one[2])
	end
	return { table.concat(symbols, "   "), table.concat(names, ", ") }
end

-- The verifications whose emoji are being compared now, by id: each is
-- asked about once.
local comparing: { [string]: boolean } = {}

backend.on_verify(function(key: string, about: any)
	local id = about.id
	local state = about.state
	if state == "compare" and comparing[id] then
		return
	elseif state == "asked" then
		greed.spawn(function()
			local from = about.from or "Another of your devices"
			if yes(`{from} asks to verify this one. Accept? (y/n)`) then
				ask(key, "verify.accept", { id = id })
				greed.echo("accepted: compare the emoji when they show")
			else
				ask(key, "verify.cancel", { id = id })
			end
		end)
	elseif state == "compare" then
		comparing[id] = true
		greed.spawn(function()
			local shown = show("Compare these with your other device", M.emoji_lines(about.emoji))
			local same = yes("The same on your other device? (y/n)")
			shown:close()
			comparing[id] = nil
			ask(key, "verify.confirm", { id = id, same = same })
		end)
	elseif state == "done" then
		greed.echo("verified: this device reads what your others do")
	elseif state == "cancelled" then
		greed.echo(`verification called off: {about.why or "by the other device"}`)
	end
end)

return M

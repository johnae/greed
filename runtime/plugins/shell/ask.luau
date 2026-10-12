-- Asking a model for a command. A line that starts with `?` (`? list the
-- biggest files here`), ends with one (`how do I undo the last commit?`),
-- or has one between what's typed so far and a question (`ls | where ? only
-- files over 1 MB`) goes to the model playing `shell-ask-role`, with the
-- shell's folder, which shell it is and the last few blocks. Its answer
-- goes to the prompt for you to read, change and run; nothing runs by
-- itself. What blocks printed goes to the model marked as someone else's
-- text.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local run = require("./run")
local fallback = require("./fallback")

type Shell = state.Shell

local M = {}

greed.option.define({
	name = "shell-ask-role",
	doc = "The model role a line ending or starting with ? asks for a command; see :models",
	default = "fast",
})

-- How many of the latest blocks go along, and how much of each one's
-- output: its last lines, up to so many bytes.
local BLOCKS = 5
local OUTPUT_LINES = 15
local OUTPUT_BYTES = 1500

--- What's typed so far and the question, when `line` asks a model; nil
--- otherwise. A `?` at the end counts only on a line of three words or
--- more, so `ls a?` stays a glob.
function M.question(line: string): (string?, string?)
	local text = string.match(line, "^%s*(.-)%s*$") or ""
	local asked = string.match(text, "^%?%s*(.+)$")
	if asked then
		return "", asked
	end
	local draft, question = string.match(text, "^(.-)%s+%?%s+(.+)$")
	if draft and question then
		return draft, question
	end
	if string.sub(text, -1) == "?" then
		local _, words = string.gsub(text, "%S+", "")
		if words >= 3 then
			return "", text
		end
	end
	return nil, nil
end

-- The end of `text`: its last lines, within the limits.
local function tail(text: string): string
	local lines = string.split((string.gsub(text, "\n$", "")), "\n")
	local kept = table.move(lines, math.max(#lines - OUTPUT_LINES + 1, 1), #lines, 1, {})
	local out = table.concat(kept, "\n")
	if #out > OUTPUT_BYTES then
		-- From the start of a character, not in the middle of one.
		local from = #out - OUTPUT_BYTES + 1
		while from <= #out and bit32.band(string.byte(out, from), 0xC0) == 0x80 do
			from += 1
		end
		out = "…" .. string.sub(out, from)
	end
	return out
end

--- The message asking for a command: where the shell is, its last blocks
--- (their output through `untrusted`, or left out without it), what's
--- typed so far and the question.
function M.message(
	shell: Shell,
	draft: string,
	question: string,
	untrusted: ((source: string, text: string) -> string)?
): string
	local program = fallback.which()
	local lines = {
		`The shell is {program}, in the folder {core.project.tilde(shell.cwd)}.`,
	}
	if #shell.blocks > 0 then
		table.insert(lines, "The latest commands, oldest first:")
	end
	for i = math.max(#shell.blocks - BLOCKS + 1, 1), #shell.blocks do
		local block = shell.blocks[i]
		run.fill(block)
		local ended = if block.status == "running"
			then "still running"
			elseif block.signal then `stopped by {block.signal}`
			else `exit {block.code or "?"}`
		table.insert(lines, `$ {block.command}   ({ended})`)
		local out = tail(block.output)
		if untrusted and out ~= "" then
			table.insert(lines, untrusted(`what \`{block.command}\` printed`, out))
		end
	end
	if draft ~= "" then
		table.insert(lines, `What's typed at the prompt so far: {draft}`)
	end
	table.insert(lines, `The question: {question}`)
	return table.concat(lines, "\n")
end

--- Asks for a command for `line`, typed in `shell`: the answer goes to the
--- prompt, as long as the prompt still holds `line`. Without a model to
--- ask, a block says why. Waits for the answer, so only where that can.
function M.ask(
	shell: Shell,
	line: string,
	draft: string,
	question: string,
	fail: (why: string) -> ()
)
	local plugins = greed.plugin.list()
	if not table.find(plugins, "models") then
		fail("no model to ask: the models plugin isn't loaded")
		return
	end
	local models = require("@models")
	local untrusted = nil
	local note = ""
	if table.find(plugins, "agent") then
		local agent = require("@agent")
		untrusted = agent.untrusted
		note = " " .. agent.untrusted_note
	end
	local program = fallback.which()
	local role = greed.option.get("shell-ask-role") :: string
	greed.echo(`asking the {role} model for a command...`)
	local answer, err = models.ask(role, {
		system = `You write a command line for the user's shell, {program}, that does what they ask. `
			.. "Reply with only the command, on one line when it can be: no explanation, no code "
			.. "fences. It goes to their prompt, where they read, change and run it."
			.. note,
		messages = { { role = "user", content = M.message(shell, draft, question, untrusted) } },
	})
	-- Asked, whatever came of it.
	greed.echo("")
	if answer == nil then
		fail(`no answer from the {role} model: {err or "it said nothing"}`)
		return
	end
	local command = string.match(models.unfenced(answer), "^%s*(.-)%s*$") or ""
	if command == "" then
		fail(`the {role} model gave no command`)
	elseif log.prompt_text(shell) == line then
		log.set_prompt(shell, command, shell.buffer:views())
	else
		greed.echo(`suggested: {command}`)
	end
end

return M

-- Shell code in a transcript: a block of sh, bash, console and the like
-- gets buttons on its opening fence. ▶ run runs it in this project's shell,
-- as a block of its own there, with the folder's environment, showing its
-- output in a float as it comes, ctrl-c stopping it; ↳ prompt puts it at
-- that shell's prompt, in a float, to look over and change first. What
-- comes of either goes to the agent with your next message. ◆ agent runs
-- it asks the agent to run it itself; ⧉ copy copies it. Pressing one is
-- the go-ahead, by a click, enter on the fence or `space .` on it; a
-- command that looks like it destroys something still asks first.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local agent = require("@agent")

local M = {}

-- The languages whose blocks are commands for a shell.
local SHELLS: { [string]: boolean } = {
	sh = true,
	bash = true,
	zsh = true,
	fish = true,
	shell = true,
	console = true,
	["shell-session"] = true,
}

--- A shell block in a transcript: the line its opening fence is on, the
--- line its closing one is, and its commands.
export type Code = { open: number, close: number, text: string }

-- The commands in a block of `lang`: its text, or of a console session
-- (`$ make`, then what make printed), the lines after its prompts.
local function commands(lang: string, text: string): string
	if lang ~= "console" and lang ~= "shell-session" then
		return text
	end
	local lines: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local command = string.match(line, "^%s*[%$#]%s(.*)$")
		if command then
			table.insert(lines, command)
		end
	end
	return if #lines > 0 then table.concat(lines, "\n") else text
end

--- The shell blocks in `buffer` before byte `stop` (the box you write in),
--- in order, leaving out those opening on a `plain` line (a tool's output,
--- which nobody wrote to run).
function M.blocks(buffer: greed.Buffer, stop: number?, plain: { [number]: boolean }?): { Code }
	local out: { Code } = {}
	for _, code in markdown.structure(buffer).code do
		local wanted = code.closed
			and SHELLS[string.lower(code.lang)]
			and (stop == nil or code.to <= stop)
			and not (plain and plain[code.open])
		if wanted then
			local text = buffer:slice(code.code_from, code.code_to)
			table.insert(out, {
				open = code.open,
				close = code.close,
				text = commands(string.lower(code.lang), text),
			})
		end
	end
	return out
end

--- The shell block whose lines `pos` is on, of those `M.blocks` finds.
function M.at(
	buffer: greed.Buffer,
	pos: number,
	stop: number?,
	plain: { [number]: boolean }?
): Code?
	local line = buffer:line_of(pos)
	for _, code in M.blocks(buffer, stop, plain) do
		if line >= code.open and line <= code.close then
			return code
		end
	end
	return nil
end

-- What each button says and runs, in the order they show.
local BUTTONS = {
	{ text = " ▶ run ", action = "agent-code-run" },
	{ text = " ↳ prompt ", action = "agent-code-prompt" },
	{ text = " ◆ agent runs it ", action = "agent-code-ask" },
	{ text = " ⧉ copy ", action = "agent-code-copy" },
}

--- Draws the buttons on the opening fence of each shell block in `buffer`
--- that `M.blocks` finds, and gives back those blocks.
function M.draw(buffer: greed.Buffer, stop: number?, plain: { [number]: boolean }?): { Code }
	local marks: { greed.Mark } = {}
	local blocks = M.blocks(buffer, stop, plain)
	for _, code in blocks do
		local from, to = buffer:line_start(code.open), buffer:line_end(code.open)
		for _, button in BUTTONS do
			table.insert(marks, {
				from = from,
				to = to,
				style = "ui.button",
				text = button.text,
				eol = true,
				action = button.action,
			})
		end
	end
	buffer:decorate("acp-code", marks)
	return blocks
end

--- Why `text` is risky to run, as `core.risk` says: a command in it
--- destroys or stops something, like `rm`, `kill` or `kubectl delete`; nil
--- when none does.
function M.risky(text: string): string?
	return core.risk.of(text)
end

-- This project's shell, opened without showing it when there's none, or
-- nil having said the shell plugin isn't loaded.
local function project_shell(): any?
	if not table.find(greed.plugin.list(), "shell") then
		greed.echo("running code needs the shell plugin")
		return nil
	end
	local api = require("@shell")
	local here = api.list(greed.project.current().id)
	return here[#here] or api.open({ show = false })
end

-- The most lines, and bytes, of what a block printed that the agent is
-- told; the rest it can read with the shell tools.
local TAIL_LINES = 30
local TAIL_BYTES = 3000

-- The end of what `block` printed, at most `TAIL_LINES` whole lines.
local function tail(block: any): string
	local output: string = if block.output ~= "" then block.output else block.stdout .. block.stderr
	local text = core.text.trim(string.sub(output, -TAIL_BYTES))
	local lines = string.split(text, "\n")
	if #lines > TAIL_LINES then
		return table.concat(lines, "\n", #lines - TAIL_LINES + 1)
	end
	return text
end

-- What came of `block`, run from an agent's message, as a block to send
-- with the next message to it (agent.context.ran).
local function report(block: any): string
	local ended = if block.signal
		then `was stopped by {block.signal}`
		elseif block.code == 0 then "succeeded"
		else `failed with exit code {block.code or "?"}`
	return agent.context.ran({
		command = block.command,
		cwd = block.cwd,
		ended = ended,
		output = tail(block),
		id = block.uid,
	})
end

-- Who to tell when a block finishes: by its uid for one run from a
-- button, and by shell for the command put at its prompt, until a block
-- of it finishes.
local by_block: { [number]: (report: string) -> () } = {}
local by_prompt: { [any]: { command: string, tell: (report: string) -> () } } = {}
local listening = false

-- Starts telling about finished blocks, the first time.
local function listen()
	if listening then
		return
	end
	listening = true
	require("@shell").on_finish(function(shell: any, block: any)
		local tell = by_block[block.uid]
		by_block[block.uid] = nil
		local waiting = by_prompt[shell]
		if tell == nil and waiting and core.text.trim(block.command) == waiting.command then
			by_prompt[shell] = nil
			tell = waiting.tell
		end
		if tell then
			tell(report(block))
		end
	end)
	greed.plugin.cleanup(function()
		listening = false
		table.clear(by_block)
		table.clear(by_prompt)
	end)
end

--- Runs `code` in this project's shell, in the folder `cwd` (where the
--- agent works), asking first when it looks risky, and shows it running
--- in a float; `tell` gets what came of it once it's done. Its block
--- there, or nil when it didn't run.
function M.run(code: Code, cwd: string, tell: (report: string) -> ()): any?
	local shell = project_shell()
	if shell == nil then
		return nil
	end
	local why = M.risky(code.text)
	if why then
		local first = string.match(code.text, "^[^\n]*") or code.text
		local more = if string.find(code.text, "\n") then " …" else ""
		greed.echo(`run {first}{more} in the shell? It {why}. y/n`)
		local yes = greed.next_key() == "y"
		greed.echo("")
		if not yes then
			return nil
		end
	end
	listen()
	local api = require("@shell")
	local block = api.run(shell, code.text, { cwd = cwd })
	if block == nil then
		return nil
	end
	if block.status == "running" then
		by_block[block.uid] = tell
		api.peek(shell, block, { tail = true })
	else
		tell(report(block))
	end
	greed.echo("what comes of it goes with your next message")
	return block
end

--- Puts `code` at the prompt of this project's shell, shown in a float
--- over the transcript, typing; once it's run from there, `tell` gets
--- what came of it.
function M.to_prompt(code: Code, tell: (report: string) -> ())
	local shell = project_shell()
	if shell == nil then
		return
	end
	listen()
	local api = require("@shell")
	api.set_prompt(shell, code.text)
	by_prompt[shell] = { command = core.text.trim(code.text), tell = tell }
	local view = greed.float(shell.buffer, {
		title = shell.name :: string,
		width = "80%",
		height = "60%",
		tab = true,
		footer = "enter runs it · what comes of it goes with your next message",
	})
	api.show(shell, view)
end

--- What to send the agent to have it run `code` itself.
function M.ask(code: Code): string
	return `Run this for me and tell me what came of it:\n\n\`\`\`sh\n{code.text}\n\`\`\``
end

--- Copies `code`'s commands.
function M.copy(code: Code)
	greed.clipboard.set(code.text)
	local _, breaks = string.gsub(code.text, "\n", "")
	greed.echo(if breaks > 0 then `copied {breaks + 1} lines` else `copied {code.text}`)
end

return M

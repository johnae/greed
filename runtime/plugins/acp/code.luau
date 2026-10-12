-- Shell code in a transcript: a block of sh, bash, console and the like
-- gets buttons on its opening fence. ▶ run runs it in this project's shell,
-- as a block of its own there, with the folder's environment, its output
-- as it comes and ctrl-c; ↳ prompt puts it at that shell's prompt to look
-- over and change first; ⧉ copy copies it. Pressing one is the go-ahead,
-- by a click, enter on the fence or `space .` on it; a command that looks
-- like it destroys something still asks first.

local greed = require("@greed")
local markdown = require("@markdown")

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
	{ text = " ⧉ copy ", action = "agent-code-copy" },
}

--- Draws the buttons on the opening fence of each shell block in `buffer`
--- that `M.blocks` finds.
function M.draw(buffer: greed.Buffer, stop: number?, plain: { [number]: boolean }?)
	local marks: { greed.Mark } = {}
	for _, code in M.blocks(buffer, stop, plain) do
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
end

-- Commands that destroy something, or stop it, asked about before they run.
local RISKY = {
	"^%s*sudo%s",
	"^%s*rm%s",
	"^%s*kill%s",
	"^%s*pkill%s",
	"^%s*killall%s",
	"^%s*dd%s",
	"^%s*mkfs",
	"^%s*shutdown",
	"^%s*reboot",
	"^%s*git%s+push%s.*%-%-force",
	"^%s*git%s+push.*%s%-f%f[^%w%-]",
	"^%s*git%s+reset%s+%-%-hard",
	"^%s*git%s+clean%s",
	"^%s*jj%s+abandon",
	"^%s*kubectl%s+delete",
	"^%s*kubectl%s+drain",
	"^%s*docker%s+rm",
	"^%s*docker%s+system%s+prune",
	"^%s*terraform%s+destroy",
	"^%s*terraform%s+apply",
}

--- Whether `text` has a command in it that destroys or stops something,
--- like `rm`, `kill` or `kubectl delete`, on a line of its own or after
--- `;`, `&&`, `||` or `|`.
function M.risky(text: string): boolean
	for command in string.gmatch(text, "[^\n;&|]+") do
		for _, pattern in RISKY do
			if string.find(command, pattern) then
				return true
			end
		end
	end
	return false
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

--- Runs `code` in this project's shell, in the folder `cwd` (where the
--- agent works), asking first when it looks risky: its block there, or nil
--- when it didn't run.
function M.run(code: Code, cwd: string): any?
	local shell = project_shell()
	if shell == nil then
		return nil
	end
	if M.risky(code.text) then
		local first = string.match(code.text, "^[^\n]*") or code.text
		greed.echo(
			`run {first}{if string.find(code.text, "\n") then " …" else ""} in the shell? y/n`
		)
		local yes = greed.next_key() == "y"
		greed.echo("")
		if not yes then
			return nil
		end
	end
	local block = require("@shell").run(shell, code.text, { cwd = cwd })
	if block then
		greed.echo(`running as block {block.number} in {shell.name} · space o w shows it`)
	end
	return block
end

--- Puts `code` at the prompt of this project's shell, and shows it there
--- in `view`, typing.
function M.to_prompt(code: Code, view: greed.View)
	local shell = project_shell()
	if shell == nil then
		return
	end
	local api = require("@shell")
	api.set_prompt(shell, code.text)
	api.show(shell, view)
end

--- Copies `code`'s commands.
function M.copy(code: Code)
	greed.clipboard.set(code.text)
	local _, breaks = string.gsub(code.text, "\n", "")
	greed.echo(if breaks > 0 then `copied {breaks + 1} lines` else `copied {code.text}`)
end

return M

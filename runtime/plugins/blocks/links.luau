-- Command buttons in Markdown: `[Run the tests](run:cargo test {{ crate }})`
-- shows as a button, and pressing it runs the command in the project's
-- shell, where its output shows. A `{{ formula }}` in the command is
-- worked out as values are (markdown's values.luau), and each goes in as
-- one argument, quoted, never as more of the command: a field holding
-- `x; rm -rf ~` stays a single argument.
--
-- The label hides the command, so a button runs without asking only when
-- its command is as you last let it run from that file; otherwise Greed
-- shows the command and asks: y runs it this time, a always.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local shell = require("@shell")

local M = {}

-- What `a` and `y` let run: the approvals blocks keep (`approved`,
-- `approve`), passed in by blocks so the two share them.
export type Approvals = {
	approved: (key: string, text: string) -> boolean,
	approve: (key: string, texts: { string }) -> (),
}

local approvals: Approvals? = nil

--- Uses `with` to keep what you let run.
function M.use(with: Approvals)
	approvals = with
end

--- A button: its label, its command as written, and where it is in its
--- line (1-based, inclusive).
export type Button = { label: string, command: string, from: number, to: number }

--- The buttons in `line`, outside code spans.
function M.buttons(line: string): { Button }
	local out: { Button } = {}
	for from, label, command, to in string.gmatch(line, "()%[([^%]]+)%]%(run:([^%)]+)%)()") do
		local before = string.sub(line, 1, (from :: number) - 1)
		local _, ticks = string.gsub(before, "`", "")
		if ticks % 2 == 0 then
			table.insert(out, {
				label = label :: string,
				command = command :: string,
				from = from :: number,
				to = (to :: number) - 1,
			})
		end
	end
	return out
end

--- `button`'s command as it runs in `buffer`: each `{{ formula }}` worked
--- out and quoted as one argument. Nil and why, when one goes wrong.
function M.line(buffer: greed.Buffer, button: Button): (string?, string?)
	local scope = markdown.values.scope(buffer)
	local failed: string? = nil
	local line = string.gsub(button.command, "{{(.-)}}", function(source: string): string
		local f, err = core.formula.compile(source)
		local value: any = nil
		if f then
			value, err = core.formula.eval(f, scope)
		end
		if err then
			failed = failed or `\{\{{source}}}: {err}`
			return ""
		end
		return shell.parse.quote(core.formula.show(value))
	end)
	if failed then
		return nil, failed
	end
	return line, nil
end

-- The button in `buffer` at `pos`.
local function button_at(buffer: greed.Buffer, pos: number): Button?
	local line = buffer:line_of(pos)
	local col = pos - buffer:line_start(line) + 1
	for _, button in M.buttons(buffer:line_text(line)) do
		if col >= button.from and col <= button.to then
			return button
		end
	end
	return nil
end

--- Presses `button` of `buffer`: runs its command in the project's shell,
--- asking first unless it's as you last let it run.
function M.press(buffer: greed.Buffer, button: Button): shell.Block?
	local line, err = M.line(buffer, button)
	if line == nil then
		greed.echo(`{button.label}: {err}`)
		return nil
	end
	local path = buffer:path()
	local text = `run:{button.command}`
	local known = approvals
	if path and known and not known.approved(path, text) then
		greed.echo(`run \`{line}\`? y yes, a always for this command, n no`)
		local key = greed.next_key()
		if key == "a" then
			known.approve(path, { text })
		elseif key ~= "y" then
			greed.echo("nothing ran")
			return nil
		end
		greed.echo("")
	end
	return shell.run(shell.project(), line)
end

greed.command({
	name = "markdown-run",
	doc = "Press the command button at the cursor, [label](run:command) in Markdown",
	run = function(ctx)
		local button = button_at(ctx.buffer, ctx.view:cursor())
		if button == nil then
			greed.echo("there's no command button here")
			return
		end
		M.press(ctx.buffer, button)
	end,
})

-- Buttons drawn over Markdown that shows as a document.
markdown.conceal({
	ns = "blocks-links",
	wants = markdown.drawn,
	draw = function(_buffer, s, first, last): { greed.Mark }
		local out: { greed.Mark } = {}
		for n = first, math.min(last, #s.lines - 1) do
			local text = s.lines[n + 1]
			if s.code_at[n] or not string.find(text, "](run:", 1, true) then
				continue
			end
			for _, button in M.buttons(text) do
				table.insert(out, {
					from = s.starts[n + 1] + button.from - 1,
					to = s.starts[n + 1] + button.to,
					style = "blocks.run",
					text = `▶ {button.label}`,
					conceal = true,
					reveal = "auto" :: "auto",
					action = "markdown-run",
				})
			end
		end
		return out
	end,
})

return M

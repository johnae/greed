-- Running a line's programs and table stages: the stages at its start,
-- `each`, programs whose output goes on to more stages (read as a table),
-- and what's left for a real shell (fallback.luau).

local greed = require("@greed")
local state = require("./state")
local run = require("./run")
local pty = require("./pty")
local fallback = require("./fallback")
local envs = require("./envs")
local kinds = require("./kinds")
local tables = require("./tables")
local builtins = require("./builtins")

type Shell = state.Shell
type Block = state.Block

local M = {}

export type RunOptions = {
	--- "user" (the default) or "agent", for an agent's tools: its block is
	--- marked as an agent's and runs in `sh`, its cd and export show in it
	--- but don't change the shell, and it skips history and aliases. A
	--- plugin's lines leave it out.
	by: string?,
	--- The folder and variables to run with, instead of the shell's.
	cwd: string?,
	env: { [string]: string | false }?,
	--- The view it was typed in, where a handoff shows.
	view: greed.View?,
	--- How programs run: "pty" (a pseudo terminal, the default for the
	--- user's commands) or "pipe" (output and errors apart, the default
	--- for an agent's).
	runner: ("pty" | "pipe")?,
	--- Set once aliases have been put in, so they aren't again.
	expanded: boolean?,
	--- What was typed, shown in the block, when that isn't `line`.
	typed: string?,
	--- A finished block of the shell's to run in, in place of a new one;
	--- see `change`.
	block: Block?,
	--- The shell a line that needs one runs in, without its startup files,
	--- e.g. "sh" for a line written for anyone's machine, like a Markdown
	--- file's button. Your own shell when left out (an agent's: "sh").
	program: string?,
}

-- Starts `argv` for `block`: in a pseudo terminal, handed to a terminal
-- right away for a line typed with `!`, or through a pipe for an agent,
-- when asked, or for data going in (`input`) or out to a buffer.
local function start(
	shell: Shell,
	block: Block,
	argv: { string },
	opts: RunOptions,
	handoff: boolean,
	input: string?,
	before: ((code: number?, signal: string?) -> ())?
)
	local runner = opts.runner or (if block.by == "agent" then "pipe" else "pty")
	if input or block.target then
		runner = "pipe"
	end
	if runner == "pipe" and not handoff then
		block.runner = "pipe"
		run.pipe(shell, block, argv, before, input)
	else
		pty.start(shell, block, argv, { terminal = handoff, before = before })
	end
end

-- Runs `line` for `block` in a real shell: the one it asks for (`sh` for
-- an agent's), else the user's with its startup files. A user's cd and
-- export carry over to their commands after.
local function fall_back(
	shell: Shell,
	block: Block,
	line: string,
	opts: RunOptions,
	handoff: boolean,
	input: string?
)
	local agent = block.by == "agent"
	envs.prepare(shell, block)
	local wrapped =
		fallback.prepare(block, line, { program = block.runs_in, rc = block.runs_in == nil })
	start(shell, block, wrapped.argv, opts, handoff, input, function()
		local cwd, changed = fallback.collect(block, wrapped)
		if not agent then
			if cwd then
				run.move(shell, cwd)
			end
			if changed then
				run.set_env(shell, changed)
			end
		end
	end)
end

-- Runs `line`, programs with `input` going in, in a real shell for
-- `block`, and gives back what they printed, their errors and how they
-- exited (nil when stopped). Interrupting the block stops them. What they
-- print goes to the table stages after them, so it isn't shown.
local function capture(
	shell: Shell,
	block: Block,
	line: string,
	input: string?
): (string, string, number?)
	local own, own_errors, own_code = builtins.capture(shell, block, line)
	if own then
		return own, own_errors, own_code
	end
	envs.prepare(shell, block)
	local wrapped = fallback.prepare(block, line, { program = block.runs_in, rc = false })
	local ran, err = greed.process.run(wrapped.argv, {
		cwd = block.cwd,
		env = state.environment(block),
		group = true,
		stdin = input,
		on_start = function(c: greed.Child)
			state.give_job(block, {
				interrupt = function()
					c:signal("INT")
				end,
				kill = function()
					c:kill()
				end,
			})
		end,
	})
	if ran == nil then
		return "", err or `can't start {wrapped.argv[1]}`, 127
	end
	block.job = nil
	-- A pipeline's cd and export are its own.
	fallback.collect(block, wrapped)
	block.cwd_after, block.env_changed = nil, nil
	return ran.stdout, ran.stderr, ran.code
end

-- `template` once for each row of `tbl`, a line each, its `{COL}`s the
-- row's cells quoted for the shell `program` (yours unless given); braces
-- naming no column stay as they are. Nil and why when `tbl` isn't a table
-- or `template` names no column.
local function each_lines(
	tbl: tables.Table?,
	template: string,
	program: string?
): (string?, string?)
	if tbl == nil then
		return nil,
			"each works on a table, and this isn't one; columns, from csv/tsv/json, split or lines make one"
	end
	local named = false
	for name in string.gmatch(template, "{([^{}]+)}") do
		named = named or tables.column(tbl, name) ~= nil
	end
	if not named then
		local example = tbl.columns[1] or "COL"
		return nil,
			`each runs a command for every row with its cells in it, like each echo \{{example}\}; there's {table.concat(
				tbl.columns,
				", "
			)}`
	end
	local lines: { string } = {}
	for _, row in tbl.rows do
		local line = string.gsub(template, "{([^{}]+)}", function(name: string): string
			local column = tables.column(tbl, name)
			return if column then fallback.quote(row[column] or "", program) else "{" .. name .. "}"
		end)
		table.insert(lines, line)
	end
	return table.concat(lines, "\n"), nil
end

-- Starts `line`'s programs in a real shell for `block`, to read what they
-- print as it comes: the program, or nil and why, and what to do once it's
-- done.
function M.open_stream(shell: Shell, block: Block, line: string): (greed.Child?, string?, () -> ())
	envs.prepare(shell, block)
	local wrapped = fallback.prepare(block, line, { program = block.runs_in, rc = false })
	local child, err = greed.process.spawn(wrapped.argv, {
		cwd = block.cwd,
		env = state.environment(block),
		stderr = "stream",
		group = true,
	})
	return child,
		err,
		function()
			-- A stream's cd and export are its own.
			fallback.collect(block, wrapped)
			block.cwd_after, block.env_changed = nil, nil
		end
end

-- What `programs` printed, `out`, as JSON and as a table for the stages
-- after them: the table nu gave back when it drew one, else `out` read as
-- JSON or as text. What nu gave back goes to the stages, so it isn't the
-- block's own value in the end.
local function read_output(block: Block, out: string, programs: string): (any, tables.Table?)
	local given = block.data
	block.data = nil
	local json = if given ~= nil then given else tables.json(out)
	return json, tables.from_value(json) or tables.parse(out, programs, block)
end

-- Runs `programs`, whose output goes on to table stages: as its kind
-- says it prints JSON (`kubectl get pods -o json`) when it says, read as
-- the table that is, so the stages read data rather than columns on
-- screen; else, or when that fails, as typed. What it printed (the table
-- as text, when it was read from JSON), its errors, how it exited (nil when
-- stopped), and its JSON and table.
local function capture_programs(
	shell: Shell,
	block: Block,
	programs: string,
	text: string?
): (string, string, number?, any, tables.Table?)
	local structured, from_json = kinds.structured(programs)
	if structured and from_json then
		local out, errors, code = capture(shell, block, structured, text)
		if code == nil then
			return out, errors, code, nil, nil
		end
		if code == 0 then
			-- JSON lines, as docker prints, aren't one value: the kind reads the text.
			local read, value = pcall(tables.json, out)
			local ok, made = pcall(from_json, if read then value else nil, out)
			if ok and made then
				block.note = `read as data: {structured}`
				return tables.text(made), errors, code, nil, made
			end
		end
	end
	local out, errors, code = capture(shell, block, programs, text)
	if code == nil or (out == "" and code ~= 0) then
		return out, errors, code, nil, nil
	end
	local json, made = read_output(block, out, programs)
	return out, errors, code, json, made
end

-- How a line worked out: printed `out` (a table, `tbl`, when it was one),
-- failed with `why`, was stopped after printing `out` or exited with
-- `code` having printed nothing, or leaves `line` to a real shell, given
-- `text`.
type Outcome =
	{ kind: "done", out: string, tbl: tables.Table? }
	| { kind: "failed", why: string }
	| { kind: "stopped", out: string }
	| { kind: "exited", code: number }
	| { kind: "shell", line: string, text: string?, handoff: boolean }

-- Works `line` out for `block` on `text`, what goes into it (with `value`
-- when that was JSON and `tbl` when it was a table): the table stages at
-- its start, `each`, then the programs after them, whose output goes on to
-- the table stages after them, as in `kubectl get pods | where STATUS !=
-- Running`, read as a table as a block's output is. What's left for a real
-- shell, it says. The programs' errors go to `errors` as they come. With
-- `raw` the line starts with a program, `^sort`; with `handoff` it runs in
-- a terminal.
local function evaluate(
	shell: Shell,
	block: Block,
	line: string,
	text: string?,
	value: any,
	tbl: tables.Table?,
	flags: { raw: boolean?, handoff: boolean? },
	errors: (string) -> ()
): Outcome
	while true do
		if text ~= nil and not flags.raw then
			local staged, rest, why, json =
				tables.pipeline(tbl, text, line, value, { block = block, shell = shell })
			if why then
				return { kind = "failed", why = why }
			end
			if staged or json ~= nil then
				local out = if staged then tables.text(staged) else tables.value_text(json) .. "\n"
				if rest == nil then
					return { kind = "done", out = out, tbl = staged }
				end
				line, text, value, tbl = rest, out, if staged then nil else json, staged
			end
		end
		block.via = "shell"
		local template = string.match(line, "^%s*each%s+(.-)%s*$")
		if template and text ~= nil and not flags.raw then
			local script, why = each_lines(tbl or tables.from_value(value), template, block.runs_in)
			if script == nil then
				return { kind = "failed", why = why or "" }
			elseif script == "" then
				return { kind = "done", out = "" }
			end
			return { kind = "shell", line = script, handoff = false }
		end
		local programs, stages = tables.after_programs(line)
		if programs == nil or stages == nil or flags.handoff then
			return { kind = "shell", line = line, text = text, handoff = flags.handoff == true }
		end
		local out, said, code, json, made = capture_programs(shell, block, programs, text)
		if said ~= "" then
			errors(said)
		end
		if code == nil then
			return { kind = "stopped", out = out }
		elseif out == "" and code ~= 0 then
			return { kind = "exited", code = code }
		end
		line, text, value, tbl, flags = stages, out, json, made, {}
	end
end

-- Runs `line` once as `flow` would, but gives back what it printed in the
-- end rather than showing it, its errors and how it exited (nil when
-- stopped).
function M.capture_all(
	shell: Shell,
	block: Block,
	line: string,
	text: string?,
	value: any,
	tbl: tables.Table?
): (string, string, number?)
	local said: { string } = {}
	local outcome = evaluate(shell, block, line, text, value, tbl, {}, function(piece: string)
		table.insert(said, piece)
	end)
	local errors = table.concat(said)
	if outcome.kind == "done" then
		return outcome.out, errors, 0
	elseif outcome.kind == "failed" then
		return "", errors .. outcome.why .. "\n", 2
	elseif outcome.kind == "stopped" then
		return outcome.out, errors, nil
	elseif outcome.kind == "exited" then
		return "", errors, outcome.code
	end
	local out, more, code = capture(shell, block, outcome.line, outcome.text)
	return out, errors .. more, code
end

-- Runs `line` for `block` as `evaluate` works it out, showing what it
-- prints.
function M.flow(
	shell: Shell,
	block: Block,
	line: string,
	opts: RunOptions,
	text: string?,
	value: any,
	tbl: tables.Table?,
	flags: { raw: boolean?, handoff: boolean? }
)
	local outcome = evaluate(shell, block, line, text, value, tbl, flags, function(errors: string)
		run.write(shell, block, errors, "stderr")
	end)
	if outcome.kind == "done" then
		block.table = outcome.tbl
		if outcome.out ~= "" then
			run.write(shell, block, outcome.out, "stdout")
		end
		run.finish(shell, block, 0, nil)
	elseif outcome.kind == "failed" then
		run.fail(shell, block, outcome.why, 2)
	elseif outcome.kind == "stopped" then
		run.finish(shell, block, nil, "INT")
	elseif outcome.kind == "exited" then
		run.finish(shell, block, outcome.code, nil)
	else
		fall_back(shell, block, outcome.line, opts, outcome.handoff, outcome.text)
	end
end

return M

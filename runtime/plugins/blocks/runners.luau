-- What runs a block, by its language: programs (`sh`, `python`, ...) get
-- the code as an argument and the input on stdin, `luau` runs in the
-- editor, and `http` sends the request it describes. Plugins add their own
-- with `add`.

local greed = require("@greed")
local registry = require("@core").registry
local scene = require("@scene")

local M = {}

--- A block to run: its code, the result of the block named by its `input`
--- option if it has one, its options, and the folder to run it in.
--- `progress` takes how much output there is so far, for showing it while
--- it runs; `started` takes a child process, so the run can be stopped.
--- `answers` are the page's answers by question (markdown questions), and
--- `answer` the one that just changed, for a block run by a pick. `live`
--- is for a block that goes on after its runner returns, as a live shell
--- block does: `stop` ends it when the block's stopped or goes away, and
--- what `live` gives back saves a new outcome as its result, outside undo.
export type Run = {
	code: string,
	input: string?,
	opts: { [string]: string },
	dir: string,
	progress: (output: string) -> (),
	started: (child: greed.Child) -> (),
	answers: { [string]: string }?,
	answer: string?,
	live: (stop: () -> ()) -> (outcome: Outcome) -> (),
}

--- What a run drew besides its text, as a chart does: its lines' styles,
--- and a scene over them for the clients that draw one better.
export type Drawing = { lines: { scene.Line }, scene: number, cols: number }

--- What a run gave: its output, how a program exited (nil for a runner
--- without exit codes), or what went wrong, and what it drew.
export type Outcome = { output: string, exit: number?, error: string?, drawing: Drawing? }

export type Runner = (run: Run) -> Outcome

local runners: { [string]: { run: Runner, by: string? } } = {}

--- Makes blocks in language `name` run with `run`. It goes when the plugin
--- that added it does, or when what it returns is called. A third
--- argument, once the plugin's name, is ignored. It runs within the limit
--- of the plugin that added it, so a runner can do no more than its plugin.
function M.add(name: string, run: Runner, _plugin: string?): () -> ()
	local remove = registry.set(runners, name, { run = run, by = greed.plugin.caller() })
	greed.plugin.tie(remove)
	return remove
end

--- The runner for blocks in language `name`, if there is one.
function M.get(name: string): Runner?
	local entry = runners[name]
	if entry == nil then
		return nil
	end
	return function(run: Run): Outcome
		return greed.plugin.within(entry.by, entry.run, run)
	end
end

--- The languages blocks can run in, sorted.
function M.names(): { string }
	local names = {}
	for name in runners do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- A runner for a program that takes code as its last argument, e.g.
--- `{ "python3", "-c" }`. The input goes to its stdin, and its output and
--- then its errors are the result.
function M.program(command: { string }): Runner
	return function(run: Run): Outcome
		local args = table.clone(command)
		table.insert(args, run.code)
		-- What the page's questions were answered, for a block that asks.
		local env: { [string]: string | false } = {
			ANSWER = if run.answer then run.answer else false,
			ANSWERS = if run.answers then greed.json.encode(run.answers) else false,
		}
		-- A group of its own, so stopping it stops what it started too, like a
		-- server a script runs.
		local child, err = greed.process.spawn(args, { cwd = run.dir, group = true, env = env })
		if child == nil then
			return { output = "", error = err or `can't start {command[1]}` }
		end
		run.started(child)
		if run.input then
			child:write(run.input)
		end
		child:close()
		local parts: { string } = {}
		while true do
			local piece = child:read()
			if piece == nil then
				break
			end
			table.insert(parts, piece)
			run.progress(table.concat(parts))
		end
		local exit = child:wait()
		local output, errors = table.concat(parts), child:stderr()
		if errors ~= "" then
			output = if output == "" or string.sub(output, -1) == "\n"
				then output .. errors
				else output .. "\n" .. errors
		end
		return { output = output, exit = exit }
	end
end

for name, command in
	{
		sh = { "sh", "-c" },
		bash = { "bash", "-c" },
		zsh = { "zsh", "-c" },
		fish = { "fish", "-c" },
		python = { "python3", "-c" },
		node = { "node", "-e" },
		ruby = { "ruby", "-e" },
	} :: { [string]: { string } }
do
	M.add(name, M.program(command))
end

-- Statements Luau code starts with, so it isn't taken as an expression.
local STATEMENTS = { "local", "return", "if", "for", "while", "repeat", "function", "do" }

-- Whether `code` is one expression, like `1 + 1` or `greed.view():buffer():len()`,
-- whose value is the result.
local function expression(code: string): boolean
	local trimmed = string.match(code, "^%s*(.-)%s*$") or ""
	if trimmed == "" or string.find(trimmed, "\n", 1, true) then
		return false
	end
	local first = string.match(trimmed, "^([%a_]+)")
	if first and table.find(STATEMENTS, first) then
		return false
	end
	-- An assignment, `x = 1`, rather than a comparison.
	return not string.match(trimmed, "^[%w_.%[%]\"']+%s*=[^=]")
end

-- Runs the block's code with `input`, `answer` and `answers` set and `print`
-- collected, and returns what it printed followed by what it returned,
-- each value on a line.
local PRELUDE = [[
local input = %s
local answer = %s
local answers = %s
local __printed = {}
local function __show(value)
	if type(value) == "table" then
		local ok, text = pcall(require("@greed").json.encode, value)
		if ok then
			return text
		end
	end
	return tostring(value)
end
local function print(...)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, __show((select(i, ...))))
	end
	table.insert(__printed, table.concat(parts, "\t"))
end
local function __finish(...)
	for i = 1, select("#", ...) do
		table.insert(__printed, __show((select(i, ...))))
	end
	return table.concat(__printed, "\n")
end
]]

M.add("luau", function(run: Run): Outcome
	local input = if run.input then string.format("%q", run.input) else "nil"
	local body = if expression(run.code) then "return " .. run.code else run.code
	local answer = if run.answer then string.format("%q", run.answer) else "nil"
	local answers = if run.answers
		then `require("@greed").json.decode({string.format("%q", greed.json.encode(run.answers))})`
		else "{}"
	local prelude = string.format(PRELUDE, input, answer, answers)
		.. "return __finish((function()\n"
	local ok, output = greed.eval(prelude .. `{body}\nend)())`)
	if not ok then
		-- Just the message, with lines counted from the block's code.
		local _, before = string.gsub(prelude, "\n", "")
		local message = string.match(output, "^[^\n]*") or output
		message = string.gsub(message, "^runtime error: ", "")
		message = string.gsub(message, "repl:(%d+):", function(line: string)
			return `line {(tonumber(line) :: number) - before}:`
		end)
		return { output = "", error = message }
	end
	return { output = output }
end)

--- What an `http` block asks for: a first line with the method and the URL
--- (or just the URL, for GET), header lines, then after a blank line the
--- body.
function M.request(code: string): greed.HttpRequest?
	local lines = string.split(code, "\n")
	local i = 1
	while i <= #lines and string.match(lines[i], "^%s*$") do
		i += 1
	end
	local first = lines[i]
	if first == nil then
		return nil
	end
	local method, url = string.match(first, "^%s*(%u+)%s+(%S+)")
	if method == nil then
		method, url = "GET", string.match(first, "^%s*(%S+)")
	end
	if url == nil then
		return nil
	end
	local headers: { [string]: string } = {}
	i += 1
	while i <= #lines and not string.match(lines[i], "^%s*$") do
		local name, value = string.match(lines[i], "^%s*([^:]+):%s*(.-)%s*$")
		if name and value then
			headers[name] = value
		end
		i += 1
	end
	local body = table.concat(lines, "\n", i + 1)
	return {
		method = method,
		url = url :: string,
		headers = headers,
		body = if body ~= "" then body else nil,
	}
end

M.add("http", function(run: Run): Outcome
	local request = M.request(run.code)
	if request == nil then
		return { output = "", error = "an http block starts with a URL, or a method and a URL" }
	end
	local timeout = tonumber(run.opts.timeout)
	request.timeout = if timeout then timeout * 1000 else nil
	local response, err = greed.http.request(request)
	if response == nil then
		return { output = "", error = err or "the request failed" }
	end
	local lines = { `{response.status}` }
	if run.opts.headers == "true" then
		local names = {}
		for name in response.headers do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			table.insert(lines, `{name}: {response.headers[name]}`)
		end
	end
	table.insert(lines, "")
	table.insert(lines, response.body)
	return { output = table.concat(lines, "\n") }
end)

return M

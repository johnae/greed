-- Tasks: commands you run again and again, like building and testing, each
-- in a terminal of its own that stays open when it's done. `space r` picks
-- one (the last run first), `:task NAME` runs one. In its output, `] e`
-- and `space d` go to the files and lines it names.
--
-- Tasks come from your config and from the project: Cargo's build, test,
-- run and clippy, a package.json's scripts, and a Makefile's targets.
--
--     require("@terminal").tasks.lint = { command = "ruff check ." }

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

--- A command to run: a shell command line, or a program and its
--- arguments, in `cwd` (the project's folder by default).
export type Task = { command: string | { string }, cwd: string? }

local M = {}

--- Tasks from your config, by name; they win over ones found in the
--- project.
M.tasks = {} :: { [string]: Task }

-- The tasks a project's files say it has, by name.
local function found(root: string): { [string]: Task }
	local list: { [string]: Task } = {}
	if greed.fs.stat(`{root}/Cargo.toml`) then
		for _, name in { "build", "test", "run", "clippy" } do
			list[name] = { command = { "cargo", name } }
		end
	end
	local package = greed.fs.read(`{root}/package.json`)
	if package then
		local ok, decoded = pcall(greed.json.decode, package)
		if ok and type(decoded) == "table" and type(decoded.scripts) == "table" then
			for name in decoded.scripts do
				list[name] = { command = { "npm", "run", name } }
			end
		end
	end
	local makefile = greed.fs.read(`{root}/Makefile`)
	if makefile then
		for line in string.gmatch(makefile, "[^\n]+") do
			local target, after = string.match(line, "^([%w][%w_%-]*):(.?)")
			if target and after ~= "=" then
				list[target] = { command = { "make", target } }
			end
		end
	end
	return list
end

--- Every task there is for the project at `root`, by name.
function M.all(root: string?): { [string]: Task }
	local list = found(root or greed.project.current().root)
	for name, task in M.tasks do
		list[name] = task
	end
	return list
end

-- The terminal each task last ran in, and the names run, latest last.
local running: { [string]: any } = {}
local history: { string } = {}

local function remember(name: string)
	local at = table.find(history, name)
	if at then
		table.remove(history, at)
	end
	table.insert(history, name)
end

--- Runs the task `name` in a terminal below the focused view, in place
--- of its last run if that's still open. Returns false and why when
--- there's no such task.
function M.run(terminal: any, name: string): (boolean, string?)
	local task = M.all()[name]
	if task == nil then
		return false, `there's no task called {name}`
	end
	local last = running[name]
	if last and terminal.is_open(last) then
		terminal.close(last)
	end
	local command = if type(task.command) == "string"
		then { "sh", "-c", task.command }
		else task.command :: { string }
	local cwd = if task.cwd then core.project.resolve(task.cwd) else nil
	running[name] = terminal.open(command, { split = "down", keep = true, cwd = cwd })
	remember(name)
	return true, nil
end

--- Adds the task commands, running tasks in `terminal`'s terminals.
function M.setup(terminal: any)
	greed.command({
		name = "task",
		doc = "Run a task, like the project's build or tests, in a terminal that stays open; without a name, pick one",
		args = { { name = "name", doc = "e.g. test" } },
		run = function(ctx)
			local name = ctx.args[1]
			if name then
				local ok, err = M.run(terminal, name)
				if not ok then
					greed.echo(err :: string)
				end
				return
			end
			local tasks = M.all()
			local names = {}
			for known in tasks do
				table.insert(names, known)
			end
			if #names == 0 then
				greed.echo(
					"no tasks: the project has no Cargo.toml, package.json or Makefile, and none are set"
				)
				return
			end
			-- The latest run first, then the rest by name.
			table.sort(names, function(a: string, b: string)
				local ra, rb = table.find(history, a) or 0, table.find(history, b) or 0
				if ra ~= rb then
					return ra > rb
				end
				return a < b
			end)
			local items = {}
			for _, known in names do
				local command = tasks[known].command
				local shown = if type(command) == "string"
					then command
					else table.concat(command, " ")
				table.insert(items, { label = `{known}  {shown}`, value = known })
			end
			picker.pick("Tasks", items, function(item)
				M.run(terminal, item.value)
			end)
		end,
	})
	greed.keymap.bind("normal", { ["space r"] = "task" })
end

return M

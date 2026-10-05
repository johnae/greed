local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

local eval = require("@agent").eval

-- Calls the eval tool with `code` in the background, as an agent's call
-- runs, and returns a function giving what it returned (or `error: ...`).
local function call(code: string): () -> string?
	local result: string? = nil
	greed.spawn(function()
		for _, tool in agent.tools() do
			if tool.name == "eval" then
				local ok, value = pcall(tool.run, { code = code }, nil)
				result = if ok then value else `error: {value}`
			end
		end
	end)
	return function()
		return result
	end
end

local function settle(t: test.TestContext, result: () -> string?): string
	t:wait_for(function()
		return result() ~= nil
	end)
	return result() :: string
end

local function reset(mode: string, review: ((string, string) -> (string?, string?))?)
	greed.option.set("agent-eval", mode)
	eval.review = review or function()
		return nil, nil
	end
end

-- Code that edits the buffer and then needs more than the sandbox gives.
local NEEDS_MORE = [[
local greed = require("@greed")
local b = greed.view():buffer()
b:edit(function(e) e:insert(b:len(), "!") end)
greed.option.set("indent", "  ")
return "done"
]]

test("in auto, code that only reads and edits runs sandboxed, without asking", function(t)
	reset("auto")
	t:buffer("hi|")
	local got = settle(t, call("local b = require('@greed').view():buffer()\nreturn b:len()"))
	assert(got == "2", got)
	assert(#t:floats() == 0, "nothing asked")
end)

test("in auto, code that needs more asks you when there's no reviewer, and runs once", function(t)
	reset("auto")
	t:buffer("hi|")
	local result = call(NEEDS_MORE)
	t:wait(10)
	local page = greed.view():buffer():text()
	assert(string.find(page, "It would change options.", 1, true), page)
	assert(string.find(page, "none set up", 1, true), "no reviewer: " .. page)
	t:run("eval-run")
	assert(settle(t, result) == "done", tostring(result()))
	-- The sandbox's edit was taken back before the full run, so it's there once.
	assert(greed.view():buffer():text() == "hi!", greed.view():buffer():text())
	local last = eval.log[#eval.log]
	assert(last.by == "you" and last.needs == "change options", last.by)
	greed.option.set("indent", "    ")
end)

test("a reviewer can let code run, or leave it to you with its reason", function(t)
	reset("auto", function()
		return "allow", "only sets an option"
	end)
	t:buffer("hi|")
	assert(settle(t, call(NEEDS_MORE)) == "done")
	assert(eval.log[#eval.log].by == "the reviewer: only sets an option", eval.log[#eval.log].by)
	reset("auto", function()
		return "ask", "changes how the editor works"
	end)
	t:buffer("hi|")
	local result = call(NEEDS_MORE)
	t:wait(10)
	local page = greed.view():buffer():text()
	assert(string.find(page, "Reviewer: changes how the editor works", 1, true), page)
	t:run("eval-deny")
	assert(settle(t, result) == "error: the user didn't let this run", tostring(result()))
	assert(greed.view():buffer():text() == "hi", "nothing ran: " .. greed.view():buffer():text())
	greed.option.set("indent", "    ")
end)

test("ask shows every run; allow runs it; off has no eval", function(t)
	reset("ask")
	t:buffer("|")
	local result = call("1 + 1")
	t:wait(10)
	assert(string.find(greed.view():buffer():text(), "1 + 1", 1, true), "the code is shown")
	greed.view():close()
	assert(settle(t, result) == "error: the user didn't let this run", "closing denies")
	reset("allow")
	assert(settle(t, call("greed and 1 or 2")) ~= nil)
	reset("off")
	local off = settle(t, call("1 + 1"))
	assert(string.find(off, "turned off", 1, true), off)
	reset("auto")
end)

test("a page nobody answers counts as denied after five minutes", function(t)
	reset("ask")
	t:buffer("|")
	local result = call("1 + 1")
	t:wait(10)
	assert(result() == nil, "still waiting")
	t:wait(5 * 60 * 1000)
	assert(settle(t, result) == "error: the user didn't let this run", tostring(result()))
	reset("auto")
end)

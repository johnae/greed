local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local asking = require("../ask")
local log = require("../log")
local models: any = require("@models")

type Shell = typeof(shell.open())

local ask = models.ask

-- Makes the model answer `answer` (or fail with `err`), and returns what
-- it's asked.
local function stub(answer: string?, err: string?): { any }
	local asked: { any } = {}
	models.ask = function(role, request)
		table.insert(asked, { role = role, request = request })
		return answer, err
	end
	return asked
end

local function open(t: test.TestContext): Shell
	greed.option.set("shell-fallback", "sh")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

-- Fails unless the status line no longer says it's asking a model.
local function done_asking(t: test.TestContext)
	local messages = t:messages()
	local last = messages[#messages] or ""
	assert(not string.find(last, "asking the", 1, true), last)
end

-- Types `line` at the prompt and presses enter.
local function enter(t: test.TestContext, sh: Shell, line: string)
	log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
end

test("a line starting or ending with ? or with ? in it is a question", function()
	local q = asking.question
	assert(select(2, q("? list big files")) == "list big files")
	assert(select(2, q("how do I undo the last commit?")) == "how do I undo the last commit?")
	local draft, question = q("ls | where ? only files over 1 MB")
	assert(draft == "ls | where" and question == "only files over 1 MB", tostring(draft))
	assert(q("ls a?") == nil, "a glob stays a glob")
	assert(q("ls -la") == nil)
end)

test("? asks a model, and its command goes to the prompt without running", function(t)
	local asked = stub("```sh\nfind . -size +1M\n```")
	local sh = open(t)
	local before = assert(shell.run(sh, "echo secret-output", { runner = "pipe" }))
	t:wait_for(function()
		return before.status ~= "running"
	end)
	enter(t, sh, "ls | where ? only files over 1 MB")
	t:wait_for(function()
		return log.prompt_text(sh) == "find . -size +1M"
	end)
	models.ask = ask
	assert(#sh.blocks == 1, "nothing ran: " .. #sh.blocks)
	done_asking(t)
	assert(#asked == 1 and asked[1].role == "fast", tostring(asked[1] and asked[1].role))
	local said = asked[1].request.messages[1].content :: string
	assert(string.find(said, "The shell is sh", 1, true), said)
	assert(string.find(said, "$ echo secret-output   (exit 0)", 1, true), said)
	assert(
		string.find(said, "<<<(untrusted%-%x+)\nsecret%-output\n%1>>>"),
		"output marked: " .. said
	)
	assert(string.find(said, "typed at the prompt so far: ls | where", 1, true), said)
	assert(string.find(said, "The question: only files over 1 MB", 1, true), said)
	assert(string.find(asked[1].request.system, "shell, sh,", 1, true) ~= nil)
end)

test("without a model to ask, a block says so", function(t)
	stub(nil, 'no model plays the role "fast"')
	local sh = open(t)
	enter(t, sh, "? list big files")
	t:wait_for(function()
		return #sh.blocks == 1 and sh.blocks[1].status ~= "running"
	end)
	models.ask = ask
	local block = sh.blocks[1]
	assert(block.command == "? list big files" and block.status == "asked", block.status)
	assert(block.code == nil, "nothing ran, so there's no exit code")
	local status = log.status_text(block)
	assert(not string.find(status, "exit", 1, true), status)
	assert(string.find(block.output, "no model plays", 1, true), block.output)
	assert(log.prompt_text(sh) == "", log.prompt_text(sh))
	done_asking(t)
end)

test("output cut down for the model is cut between characters", function(t)
	local asked = stub("ls")
	local sh = open(t)
	-- More than the model is shown, all of it three-byte characters.
	local block = assert(shell.run(sh, "printf '✔%.0s' $(seq 1 700)", { runner = "pipe" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	enter(t, sh, "? what next")
	t:wait_for(function()
		return #asked == 1
	end)
	models.ask = ask
	local said = asked[1].request.messages[1].content :: string
	assert(utf8.len(said) ~= nil, "the message is whole characters")
	assert(string.find(said, "…✔", 1, true), "cut at a character")
end)

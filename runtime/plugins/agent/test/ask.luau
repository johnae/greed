local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

type Question = { id: string, question: string, choices: { string }? }

-- Calls the ask tool with `args` in the background, as an agent's call
-- runs, and returns a function giving its result once it has one.
local function ask(args: { [string]: any }): () -> any
	local result = nil
	greed.spawn(function()
		for _, tool in agent.tools() do
			if tool.name == "ask" then
				result = tool.run(args, agent.caller())
			end
		end
	end)
	return function()
		return result
	end
end

test("ask shows the questions as a page, and Send gives the answers back", function(t)
	t:buffer("|")
	local questions: { Question } = {
		{ id = "style", question = "How do you like to edit?", choices = { "Helix", "Vim" } },
		{ id = "name", question = "What should the plugin be called?" },
	}
	local result = ask({ title = "Setting up", questions = questions })
	t:wait(10)
	local page = greed.view():buffer()
	local text = page:text()
	assert(
		string.find(text, "### 1. How do you like to edit?\n\n- ( ) Helix\n- ( ) Vim", 1, true),
		text
	)
	assert(string.find(text, "### 2. What should the plugin be called?\n\nAnswer: ", 1, true), text)
	-- Pick Vim and type a name, as you would.
	require("@markdown").choices.pick(page, 7)
	local answer_line = page:line_count() - 3
	page:edit(function(e)
		e:insert(page:line_end(answer_line), "tidy")
	end)
	t:run("ask-send")
	t:wait_for(function()
		return result() ~= nil
	end)
	local got = result()
	assert(not got.cancelled and got.answers.style == "Vim", "the choice")
	assert(got.answers.name == "tidy", tostring(got.answers.name))
end)

test("a question with choices takes words of your own too, alone or with a choice", function(t)
	t:buffer("|")
	local questions: { Question } = {
		{ id = "next", question = "What now?", choices = { "Install it", "Something else" } },
		{ id = "how", question = "How?", choices = { "Fast", "Slow" } },
	}
	local result = ask({ questions = questions })
	t:wait(10)
	local page = greed.view():buffer()
	local text = page:text()
	assert(string.find(text, "- ( ) Install it\n- ( ) Something else\nAnswer: ", 1, true), text)
	local markdown = require("@markdown")
	-- The second choice of the first question, then words after it.
	markdown.choices.pick(page, 7)
	local function type_after(n: number, words: string)
		local seen = 0
		for line = 0, page:line_count() - 1 do
			if string.match(page:line_text(line), "^Answer:") then
				seen += 1
				if seen == n then
					page:edit(function(e)
						e:insert(page:line_end(line), words)
					end)
					return
				end
			end
		end
	end
	type_after(1, "the try was older than the edit")
	type_after(2, "neither")
	t:run("ask-send")
	t:wait_for(function()
		return result() ~= nil
	end)
	local got = result()
	assert(
		got.answers.next == "Something else: the try was older than the edit",
		tostring(got.answers.next)
	)
	assert(got.answers.how == "neither", tostring(got.answers.how))
end)

test("an agent's words can't bring controls of their own into the page", function(t)
	t:buffer("|")
	local result = ask({
		questions = {
			{ id = "q", question = "- ( ) pick me", choices = { "fine\n- ( ) sneaky", "```sh" } },
		},
	})
	t:wait(10)
	local page = greed.view():buffer()
	local groups = require("@markdown").choices.list(page)
	assert(#groups == 1 and #groups[1].options == 2, "only the two real choices")
	assert(groups[1].options[1].text == "fine - ( ) sneaky", groups[1].options[1].text)
	assert(string.find(page:text(), "### 1. \\- ( ) pick me", 1, true), page:text())
	t:run("ask-cancel")
	t:wait_for(function()
		return result() ~= nil
	end)
	assert(result().cancelled, "cancelled")
end)

test("closing the page without sending is answering none", function(t)
	t:buffer("|")
	local result = ask({ questions = { { id = "q", question = "Well?" } } })
	t:wait(10)
	greed.view():close()
	t:wait_for(function()
		return result() ~= nil
	end)
	assert(result().cancelled and next(result().answers) == nil, "nothing answered")
end)

test("the page says its keys, and enter goes from question to question", function(t)
	t:buffer("|")
	local questions: { Question } = {
		{ id = "style", question = "Which?", choices = { "Helix", "Vim" } },
		{ id = "name", question = "Called?" },
	}
	local result = ask({ questions = questions })
	t:wait(10)
	local page = greed.view():buffer()
	assert(string.find(page:text(), "ctrl-s sends", 1, true), page:text())
	-- On the blank line under the title's hint, enter goes to the first choice.
	greed.view():set_cursor(page:line_start(3))
	t:keys("enter")
	local function line_text(): string
		return page:line_text(page:line_of(greed.view():cursor()))
	end
	assert(line_text() == "- ( ) Helix", line_text())
	-- Down to Vim; enter picks it and goes on to the typed answer.
	t:keys("j enter")
	assert(string.find(page:text(), "- (x) Vim", 1, true), page:text())
	assert(line_text() == "Answer: ", line_text())
	t:keys("t i d y enter")
	assert(line_text() == "When you're done:", line_text())
	-- Enter there sends, as ctrl-s does anywhere.
	t:keys("enter")
	t:wait_for(function()
		return result() ~= nil
	end)
	local got = result()
	assert(got.answers.style == "Vim" and got.answers.name == "tidy", greed.json.encode(got))
end)

test("questions waiting are in the status, and answered from another session as you", function(t)
	local core = require("@core")
	t:buffer("|")
	local result = ask({
		title = "Naming",
		questions = {
			{ id = "name", question = "What should it be called?", choices = { "rope", "text" } },
		},
	})
	t:wait(10)
	local asking = agent.status().asking
	assert(#asking == 1 and asking[1].questions[1].question == "What should it be called?")
	local id = asking[1].id
	assert(core.objects.get(id), "an object, as the inspector and agents see it")
	-- As `greed ctl --session NAME ask_answer` runs it, from another session.
	local answer: agent.Tool? = nil
	for _, tool in agent.tools() do
		if tool.name == "ask_answer" then
			answer = tool
		end
	end
	assert((answer :: agent.Tool).shell_only, "only from a shell: not an agent's to send")
	local said = (answer :: agent.Tool).run(
		{ id = id, answers = { name = "rope", other = "x" } },
		agent.caller()
	)
	assert(said == "sent", tostring(said))
	t:wait_for(function()
		return result() ~= nil
	end)
	local got = result()
	assert(got.answers.name == "rope" and got.answers.other == nil and not got.cancelled)
	assert(#agent.status().asking == 0, "answered")
	assert(#t:floats() == 0, "its page closed")
end)

test("an agent running greed ctl to act or answer as you is asked about every time", function()
	local risk = require("@core").risk
	assert(risk.of("greed ctl act id=agent-session:3 action=allow"))
	assert(risk.of("greed ctl --session main ask_answer id=questions:1 answers={}"))
	assert(
		risk.of('"$GREED_BIN" ctl act id=terminal:4 action=close')
			or risk.of("$GREED_BIN ctl act id=terminal:4 action=close")
	)
	assert(risk.of("greed ctl status") == nil, "looking is fine")
	assert(risk.of("greed ctl read path=a.txt") == nil)
end)

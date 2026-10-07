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
	require("@markdown").choices.pick(page, 5)
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

-- Questions from agents: the `ask` tool shows them as a Markdown page in a
-- float, you answer (pick a choice, type after "Answer:"), and Send gives
-- the answers back to the agent.
--
-- Agents send questions as data, never as Markdown: Greed writes the page,
-- each of the agent's words on a line of its own with anything that could
-- start Markdown's syntax escaped, so a question can't bring a button, a
-- code block or a choice of its own. Only you can send the answers.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local registry = require("./registry")

local M = {}

--- A question: its `id` (the key of its answer), the question, and either
--- `choices` to pick one of or nothing, for an answer typed in.
export type Question = { id: string, question: string, choices: { string }? }

-- A question being asked: its page, its questions, and who waits.
type Asking =
	{ buffer: greed.Buffer, view: greed.View?, questions: { Question }, done: greed.Signal }

local asking: { Asking } = {}

-- `text` on one line, with what could start Markdown's syntax at its
-- beginning escaped, so it reads as the words it is.
local function plain(text: string): string
	local line = string.gsub(string.gsub(text, "[\r\n]+", " "), "^%s+", "")
	if
		string.match(line, "^[-*+#>`~|]")
		or string.match(line, "^%d+[.)]")
		or string.match(line, "^Answer:")
	then
		line = "\\" .. line
	end
	return line
end

-- The page for `questions`.
local function page(title: string, questions: { Question }): string
	local lines = { `# {plain(title)}`, "" }
	for n, q in questions do
		table.insert(lines, `### {n}. {plain(q.question)}`)
		table.insert(lines, "")
		if q.choices and #q.choices > 0 then
			for _, choice in q.choices do
				table.insert(lines, `- ( ) {plain(choice)}`)
			end
		else
			table.insert(lines, "Answer: ")
		end
		table.insert(lines, "")
	end
	table.insert(lines, "When you're done:")
	return table.concat(lines, "\n")
end

-- The answers on `buffer`'s page, by question id: the choice picked, or
-- the words after "Answer:", nil for none.
local function answers(buffer: greed.Buffer, questions: { Question }): { [string]: string }
	local picked: { [number]: string } = {}
	for _, group in markdown.choices.list(buffer) do
		for _, option in group.options do
			if option.picked then
				picked[group.line] = option.text
			end
		end
	end
	local out: { [string]: string } = {}
	local n = 0
	for line = 0, buffer:line_count() - 1 do
		local text = buffer:line_text(line)
		local number = string.match(text, "^### (%d+)%. ")
		if number then
			n = tonumber(number) :: number
		end
		local q = questions[n]
		if q then
			local typed = string.match(text, "^Answer:%s*(.-)%s*$")
			if typed and typed ~= "" then
				out[q.id] = typed
			elseif picked[line] then
				out[q.id] = picked[line]
			end
		end
	end
	return out
end

-- The question being asked in `buffer`, if any.
local function asked_in(buffer: greed.Buffer): Asking?
	for _, a in asking do
		if a.buffer == buffer then
			return a
		end
	end
	return nil
end

local function finish(a: Asking, result: any)
	table.remove(asking, table.find(asking, a) :: number)
	local view = a.view
	if view then
		pcall(view.close, view)
	end
	a.done:send(result)
end

--- Shows `questions` as a page and waits until you send or cancel it.
--- Returns the answers by id and whether you cancelled.
function M.ask(title: string, questions: { Question }): ({ [string]: string }, boolean)
	local buffer = greed.create_buffer("file", page(title, questions), { language = "markdown" })
	local a: Asking = { buffer = buffer, questions = questions, done = greed.signal() }
	table.insert(asking, a)
	-- Send and cancel buttons after the last line, which only you can press.
	local last = buffer:line_start(buffer:line_count() - 1)
	local function button(text: string, action: string): greed.Mark
		return {
			from = last,
			to = last,
			style = "ui.button",
			text = text,
			eol = true,
			action = action,
		}
	end
	buffer:decorate("ask", { button("Send", "ask-send"), button("Cancel", "ask-cancel") })
	-- As big as the questions, with room for the buttons and to type an
	-- answer; a float bigger than the screen is drawn to fit it.
	local widest = 0
	for line = 0, buffer:line_count() - 1 do
		widest = math.max(widest, core.text.width(buffer:line_text(line)))
	end
	a.view = greed.float(buffer, {
		title = "Questions",
		width = math.max(widest + 24, 50),
		height = buffer:line_count() + 3,
	})
	local result = a.done:wait()
	return result.answers, result.cancelled
end

greed.command({
	name = "ask-send",
	doc = "Send your answers to the agent that asked these questions",
	run = function(ctx)
		local a = asked_in(ctx.buffer)
		if a == nil then
			greed.echo("there are no questions here")
			return
		end
		finish(a, { answers = answers(ctx.buffer, a.questions), cancelled = false })
	end,
})

greed.command({
	name = "ask-cancel",
	doc = "Answer none of these questions, telling the agent you didn't",
	run = function(ctx)
		local a = asked_in(ctx.buffer)
		if a then
			finish(a, { answers = {}, cancelled = true })
		end
	end,
})

-- Closing the page without sending is answering none.
greed.on("view.closed", function(event: greed.ViewClosed)
	for _, a in asking do
		local view = a.view
		if view and view:id() == event.view then
			a.view = nil
			finish(a, { answers = {}, cancelled = true })
			return
		end
	end
end)

registry.tool({
	name = "ask",
	description = "Ask the user questions and wait for their answers. Each question has an id "
		.. "(the key of its answer), the question, and either choices to pick one of or none, "
		.. "for a typed answer. Greed shows them as a page; the user answers and sends it, or "
		.. "cancels. Returns the answers by id and whether they cancelled.",
	input = registry.schema.object({
		title = { type = "string" },
		questions = {
			type = "array",
			items = registry.schema.object({
				id = { type = "string" },
				question = { type = "string" },
				choices = { type = "array", items = { type = "string" } },
			}, { "id", "question" }),
		},
	}, { "questions" }),
	run = function(args)
		local questions: { Question } = {}
		for _, q in args.questions or {} do
			if type(q) == "table" and type(q.id) == "string" and type(q.question) == "string" then
				table.insert(questions, { id = q.id, question = q.question, choices = q.choices })
			end
		end
		if #questions == 0 then
			error("ask needs at least one question with an id and the question", 0)
		end
		local answered, cancelled = M.ask(args.title or "Questions from the agent", questions)
		return { answers = answered, cancelled = cancelled }
	end,
})

return M

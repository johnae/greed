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

--- A question: its `id` (the key of its answer), the question, and
--- `choices` to pick one of, if any; an answer can be typed in too.
export type Question = { id: string, question: string, choices: { string }? }

-- Questions being asked: a number for each time, its title, its page, its
-- questions, and who waits.
type Asking = {
	id: number,
	title: string,
	buffer: greed.Buffer,
	view: greed.View?,
	questions: { Question },
	done: greed.Signal,
}

local asking: { Asking } = {}
local asked = 0

local function object_id(a: Asking): string
	return `questions:{a.id}`
end

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

-- How to answer, under the title.
local HINT = "enter picks a choice or goes on to the next question; type your answer "
	.. "after Answer:; ctrl-s sends, or Send at the end"

-- The page for `questions`.
local function page(title: string, questions: { Question }): string
	local lines = { `# {plain(title)}`, "", HINT, "" }
	for n, q in questions do
		table.insert(lines, `### {n}. {plain(q.question)}`)
		table.insert(lines, "")
		if q.choices and #q.choices > 0 then
			for _, choice in q.choices do
				table.insert(lines, `- ( ) {plain(choice)}`)
			end
		end
		-- Words of your own, for a question without choices or none that fits.
		table.insert(lines, "Answer: ")
		table.insert(lines, "")
	end
	table.insert(lines, "When you're done:")
	return table.concat(lines, "\n")
end

-- The answers on `buffer`'s page, by question id: the choice picked, the
-- words after "Answer:", or both as "choice: words"; nil for none.
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
				-- After the question's choices, so with the one picked if any.
				out[q.id] = if out[q.id] then `{out[q.id]}: {typed}` else typed
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
	core.objects.changed(object_id(a))
end

--- The questions agents wait on you for now, as the status shows them, so
--- you can answer them from another session or machine (`ask_answer`).
function M.open(): { { id: string, title: string, questions: { Question } } }
	local out = {}
	for _, a in asking do
		table.insert(out, { id = object_id(a), title = a.title, questions = a.questions })
	end
	return out
end

-- The questions asked as `questions:N`, if they wait still.
local function asking_as(id: string): Asking?
	for _, a in asking do
		if object_id(a) == id then
			return a
		end
	end
	return nil
end

local function object(a: Asking): core.Object
	return { kind = "questions", id = object_id(a), label = a.title, value = a }
end

core.objects.kind({
	name = "questions",
	doc = "Questions an agent waits on you for, on a page you answer and send",
	list = function()
		local out = {}
		for _, a in asking do
			table.insert(out, object(a))
		end
		return out
	end,
	get = function(key)
		local a = asking_as(`questions:{key}`)
		return if a then object(a) else nil
	end,
	inspect = function(a: Asking)
		return { title = a.title, questions = a.questions }
	end,
})

-- Going to them: the page, brought back if it was moved out of sight.
core.actions.action({
	kind = "questions",
	name = "show",
	doc = "Show the page to answer them on",
	run = function(target)
		local a: Asking = target.value
		local view = a.view
		if view and view:valid() then
			view:focus()
		else
			greed.view():show(a.buffer)
		end
	end,
})
core.actions.set_default("questions", "show")

--- Shows `questions` as a page and waits until you send or cancel it.
--- Returns the answers by id and whether you cancelled.
function M.ask(title: string, questions: { Question }): ({ [string]: string }, boolean)
	local buffer = greed.create_buffer("file", page(title, questions), { language = "markdown" })
	asked += 1
	local a: Asking = {
		id = asked,
		title = title,
		buffer = buffer,
		questions = questions,
		done = greed.signal(),
	}
	table.insert(asking, a)
	core.objects.changed(object_id(a))
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
	buffer:set_keys({ enter = "ask-enter", ["ctrl-s"] = "ask-send" })
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

-- The line after `line` where the next question is answered: its first
-- choice or its Answer: line, or the last line, where Send is.
local function next_answer(buffer: greed.Buffer, line: number): number
	local last = buffer:line_count() - 1
	local past_question = false
	for n = line + 1, last do
		local text = buffer:line_text(n)
		if string.match(text, "^### %d+%. ") then
			past_question = true
		elseif
			past_question and (string.match(text, "^Answer:") or markdown.choices.at(buffer, n))
		then
			return n
		end
	end
	return last
end

greed.command({
	name = "ask-enter",
	doc = "On a page of questions: pick the choice under the cursor and go on to the next question, start typing an answer, or go on; on the last line, send",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		if asked_in(buffer) == nil then
			return
		end
		local line = buffer:line_of(view:cursor())
		if line == buffer:line_count() - 1 then
			-- Where Send is; Cancel is a click, or closing the page.
			greed.run("ask-send")
			return
		end
		if string.match(buffer:line_text(line), "^Answer:") and not core.style.is_typing() then
			-- Typing after what's there.
			view:set_cursor(buffer:line_end(line))
			greed.mode.set(core.style.typing_mode())
			return
		end
		if markdown.choices.at(buffer, line) then
			markdown.choices.pick(buffer, line)
		end
		local after = next_answer(buffer, line)
		view:set_cursor(buffer:line_end(after))
		greed.mode.set(
			if string.match(buffer:line_text(after), "^Answer:")
				then core.style.typing_mode()
				else core.style.home()
		)
	end,
})

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
		.. "(the key of its answer), the question, and choices to pick one of if it has any; the "
		.. 'user can type words of their own too, which come back alone or as "choice: words". '
		.. "Greed shows them as a page; the user answers and sends it, or "
		.. "cancels. Returns the answers by id and whether they cancelled. Ask only what you "
		.. "can't settle yourself: pick names and sensible defaults on your own and say what "
		.. "you picked.",
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

registry.tool({
	name = "ask_answer",
	shell_only = true,
	description = "Answer questions an agent waits on you for (`questions:N`, as the status "
		.. "lists them), from another session or machine: `answers` by question id. As the "
		.. "Send on their page, for you only: `greed ctl --session NAME ask_answer "
		.. 'id=questions:3 answers=\'{"name": "rope"}\'`',
	input = registry.schema.object({
		id = { type = "string", description = "The questions' id, like questions:3" },
		answers = { type = "object", description = "The answers, by question id" },
	}, { "id", "answers" }),
	run = function(args)
		local a = asking_as(tostring(args.id))
		if a == nil then
			error(`no questions {args.id} wait now`, 0)
		end
		local given: { [string]: string } = {}
		local sent: { [string]: any } = if type(args.answers) == "table"
			then args.answers :: any
			else {}
		for _, q in a.questions do
			local answer = sent[q.id]
			if answer ~= nil then
				given[q.id] = tostring(answer)
			end
		end
		finish(a, { answers = given, cancelled = false })
		return "sent"
	end,
})

-- `greed ctl` acts as you, so an agent running it in a shell to answer
-- another agent, or to run an action for you, asks you every time.
for _, program in { "greed", "$GREED_BIN" } do
	core.risk.rule(program, function(words: { string }): string?
		local ctl = table.find(words, "ctl")
		if ctl == nil then
			return nil
		end
		for i = ctl + 1, #words do
			if words[i] == "act" or words[i] == "ask_answer" or words[i] == "agent_permission" then
				return "acts as you in Greed: answers an agent or runs an action"
			end
		end
		return nil
	end)
end

return M

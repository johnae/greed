-- Commands that ask a language model, in the roles :models shows, with
-- what you pinned to the context (space i p, see the context plugin):
--
--   space i e   explain the selection, in a panel as the answer arrives
--   space i a   ask something about the selection
--   space i f   fix the problem under the cursor, as changes to review
--   space i c   draft a description of the changes in progress
--
-- Fixes come as proposed changes (] o, space o a, space o r), which undo as
-- one operation. In the description buffer, a applies it (jj describe, or a
-- git commit of what's staged).

local kern = require("@kern")
local core = require("@core")
local models = require("@models")
local agent = require("@agent")
local vcs = require("@vcs")
local context = require("@context")

kern.option.define({
	name = "assist-role",
	doc = "The model role assist's commands ask; see :models",
	default = "fast",
})

local M = {}

local function role(): string
	return kern.option.get("assist-role") :: string
end

-- The panel answers show in, while it's open.
local panel: kern.View? = nil

kern.on("view.closed", function(event: kern.ViewClosed)
	if panel and panel:id() == event.view then
		panel = nil
	end
end)

--- Shows a fresh buffer of `kind` in the answer panel, titled `title`.
local function show(kind: string, title: string, language: string?): kern.Buffer
	local buffer = kern.create_buffer(kind, "", { readonly = true, language = language })
	local open = panel
	if open then
		open:show(buffer)
		open:configure({ title = title })
	else
		panel = kern.panel(buffer, { side = "right", width = "45%", title = title, focus = false })
	end
	return buffer
end

--- Asks the model and writes its answer into `buffer` as it arrives.
--- Returns the whole answer, or nil and why not.
function M.answer_into(buffer: kern.Buffer, request: models.Request): (string?, string?)
	local stream, err = models.stream(role(), request)
	if stream == nil then
		return nil, err
	end
	while true do
		local piece, failed = stream.next()
		if failed then
			return nil, failed
		end
		if piece == nil then
			return stream.text, nil
		end
		buffer:edit(function(e)
			e:insert(buffer:len(), piece)
		end)
	end
end

-- The selected text, or the line under the cursor when nothing more is
-- selected, and the 1-based line it starts on.
local function selected(view: kern.View): (string, number)
	local buffer = view:buffer()
	local selection = view:selection()
	local range = selection.ranges[selection.primary]
	local from = math.min(range.anchor, range.head)
	local to = math.max(range.anchor, range.head)
	if to - from > 1 then
		return buffer:slice(from, to), buffer:line_of(from) + 1
	end
	local line = buffer:line_of(range.head)
	return buffer:slice(buffer:line_start(line), buffer:line_end(line)), line + 1
end

-- `content` with what's pinned to the context first, when anything is.
local function with_context(content: string): string
	local pinned = context.text()
	return if pinned == "" then content else `Context I pinned:\n\n{pinned}\n\n---\n\n{content}`
end

-- Where the code comes from, for the model.
local function source(buffer: kern.Buffer, line: number): string
	return `{buffer:path() or "an unsaved buffer"}, line {line}, in {buffer:language() or "plain text"}`
end

-- Asks `question` about the selection in `view`, answering in the panel.
local function about_selection(view: kern.View, title: string, question: string)
	local text, line = selected(view)
	local buffer = show("answer", title, "markdown")
	local _, err = M.answer_into(buffer, {
		system = "You help a programmer in their editor. Answer briefly and concretely, "
			.. "in Markdown. Don't repeat the code back unless asked.",
		messages = {
			{
				role = "user",
				content = with_context(
					`{question}\n\nFrom {source(view:buffer(), line)}:\n\n{text}`
				),
			},
		},
	})
	if err then
		kern.echo(err)
	end
end

kern.command({
	name = "explain",
	doc = "Explain the selection (or the line), in a panel as the answer arrives",
	run = function(ctx)
		about_selection(ctx.view, "Explanation", "Explain what this code does and why.")
	end,
})

kern.command({
	name = "ask-about",
	doc = "Ask a language model something about the selection (or the line)",
	run = function(ctx)
		local question = core.prompt.ask("Ask about the selection")
		if question and question ~= "" then
			about_selection(ctx.view, question, question)
		end
	end,
})

-- How many lines around a problem the model sees and may change.
local AROUND = 20

-- The most severe problem on the cursor's line.
local function problem_at(view: kern.View): kern.Diagnostic?
	local buffer = view:buffer()
	local selection = view:selection()
	local line = buffer:line_of(selection.ranges[selection.primary].head)
	local best: kern.Diagnostic? = nil
	for _, d in kern.lsp.diagnostics(buffer) do
		if buffer:line_of(d.from) == line and (best == nil or d.severity < best.severity) then
			best = d
		end
	end
	return best
end

kern.command({
	name = "fix",
	doc = "Ask a language model to fix the problem under the cursor, as changes to review",
	run = function(ctx)
		local buffer = ctx.buffer
		local problem = problem_at(ctx.view)
		if problem == nil then
			kern.echo("no problem on this line")
			return
		end
		local line = buffer:line_of(problem.from)
		local first = math.max(line - AROUND, 0)
		local last = math.min(line + AROUND, buffer:line_count() - 1)
		local from = buffer:line_start(first)
		local to = if last + 1 < buffer:line_count()
			then buffer:line_start(last + 1)
			else buffer:len()
		local old = buffer:slice(from, to)
		kern.echo("asking the model for a fix...")
		local answer, err = models.ask(role(), {
			system = "You fix code. Reply with only the rewritten lines, the whole excerpt, "
				.. "changed as little as the fix needs: no explanations, no code fences.",
			messages = {
				{
					role = "user",
					content = with_context(
						`Lines {first + 1} to {last + 1} of {source(buffer, first + 1)}. `
							.. `The language server reports at line {line + 1}: {problem.message}\n\n{old}`
					),
				},
			},
		})
		if answer == nil then
			kern.echo(err :: string)
			return
		end
		local new = models.unfenced(answer)
		if string.sub(old, -1) == "\n" and string.sub(new, -1) ~= "\n" then
			new ..= "\n"
		end
		local changes = {}
		for _, change in kern.diff(old, new) do
			table.insert(
				changes,
				{ from = from + change.from, to = from + change.to, text = change.text }
			)
		end
		if #changes == 0 then
			kern.echo("the model changed nothing")
			return
		end
		agent.propose_changes(
			buffer,
			buffer:path() or "this buffer",
			changes,
			`fix: {problem.message}`
		)
	end,
})

-- The folder of the buffer, or the project's, for the repository.
local function folder(buffer: kern.Buffer): string
	local path = buffer:path()
	return if path then string.match(path, "^(.*)/[^/]*$") or "." else kern.project.current().root
end

-- Where each description buffer applies, by buffer.
local describing: { [number]: string } = {}

kern.command({
	name = "commit-message",
	doc = "Draft a description of the changes in progress, from their diff",
	run = function(ctx)
		local dir = folder(ctx.buffer)
		local diff, kind = vcs.diff(dir)
		if diff == nil then
			kern.echo(kind or "no diff")
			return
		elseif diff == "" then
			kern.echo("nothing has changed")
			return
		end
		local buffer = show("commit-message", "Description: a applies it, q closes")
		describing[buffer:id()] = dir
		local _, err = M.answer_into(buffer, {
			system = "You write commit descriptions: a first line under 72 characters in the "
				.. "imperative mood, then, only if it helps, a blank line and a short plain "
				.. "paragraph. No Markdown, no code fences.",
			messages = { { role = "user", content = `Describe these changes:\n\n{diff}` } },
		})
		if err then
			kern.echo(err)
		end
	end,
})

kern.command({
	name = "commit-message-apply",
	doc = "Use the drafted description: jj describe, or a git commit of what's staged",
	run = function(ctx)
		local dir = describing[ctx.buffer:id()]
		if dir == nil then
			return
		end
		local message = models.unfenced(ctx.buffer:text())
		local ok, err = vcs.describe(dir, (string.gsub(message, "%s+$", "")))
		kern.echo(if ok then "described" else `can't describe: {err}`)
		if ok and panel then
			panel:close()
		end
	end,
})

kern.command({
	name = "assist-close",
	doc = "Close the answer panel",
	run = function()
		if panel then
			panel:close()
		end
	end,
})

kern.on("buffer.closed", function(event: kern.BufferClosed)
	describing[event.id] = nil
end)

kern.keymap.bind("normal", {
	["space i e"] = "explain",
	["space i a"] = "ask-about",
	["space i f"] = "fix",
	["space i c"] = "commit-message",
})
kern.keymap.bind({ mode = "normal", kind = "answer" }, { q = "assist-close" })
kern.keymap.bind(
	{ mode = "normal", kind = "commit-message" },
	{ a = "commit-message-apply", q = "assist-close" }
)

return M

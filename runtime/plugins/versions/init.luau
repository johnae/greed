-- When Greed would show a session that another version of Greed runs, the
-- two can't work together. Greed then runs a Greed of its own for this page,
-- in the terminal or the window you started, which says so and asks what to
-- do: end that session and start one of this version, open it with the
-- version it runs, to save your work first, or start one beside it. Greed
-- does what's picked once the page closes.
--
--   1 2 3       pick that choice
--   enter       press the button under the cursor; tab goes to the next
--   esc, q      cancel

local greed = require("@greed")

local M = {}

--- What Greed found: the session and where it runs (`host`, nil for this
--- machine), the version it runs if it said and this one, its unsaved files
--- and what's running in it, whether that version's greed is here to open
--- it with, and the file the answer goes to.
export type Info = {
	session: string,
	host: string?,
	theirs: string?,
	ours: string,
	unsaved: { string },
	busy: { string },
	old: boolean,
	answer: string,
}

-- The choices, in order: what's written for each, and its button's words.
type Choice = { answer: string, label: string }

-- The page's info, while it shows.
local asked: Info? = nil

-- `list` in words: "a", "a and b", "a, b and c".
local function listed(list: { string }): string
	local quoted: { string } = {}
	for _, item in list do
		table.insert(quoted, `\`{item}\``)
	end
	if #quoted <= 1 then
		return quoted[1] or ""
	end
	return table.concat(quoted, ", ", 1, #quoted - 1) .. " and " .. quoted[#quoted]
end

--- The choices `info` gives, in the order they show.
function M.choices(info: Info): { Choice }
	local theirs = if info.theirs then `Greed {info.theirs}` else "the other version"
	local out: { Choice } = {}
	local losing = if #info.unsaved > 0 then ", losing those changes," else ""
	table.insert(out, { answer = "end", label = `End it{losing} and start Greed {info.ours}` })
	if info.old then
		table.insert(
			out,
			{ answer = "old", label = `Open it with {theirs}, to save your work first` }
		)
	end
	table.insert(
		out,
		{ answer = "beside", label = `Start Greed {info.ours} beside it, leaving it running` }
	)
	return out
end

--- The page's text for `info`.
function M.text(info: Info): string
	local where = if info.host then ` on {info.host}` else ""
	local theirs = if info.theirs then `Greed {info.theirs}` else "another version of Greed"
	local lines = {
		"# Another Greed is running",
		"",
		`The session **{info.session}**{where} runs {theirs}, and this is Greed {info.ours}.`
			.. " They can't work together, so this one can't show it.",
		"",
	}
	if #info.unsaved > 0 then
		table.insert(lines, `It has unsaved changes in {listed(info.unsaved)}.`)
	end
	if #info.busy > 0 then
		table.insert(lines, `Still running in it: {listed(info.busy)}.`)
	end
	if #info.unsaved > 0 or #info.busy > 0 then
		table.insert(lines, "")
	end
	table.insert(lines, "What should happen? A number picks, `esc` cancels.")
	table.insert(lines, "")
	for i, choice in M.choices(info) do
		table.insert(lines, `\`\`\`luau button="{i}  {choice.label}"`)
		table.insert(lines, `require("@versions").choose("{choice.answer}")`)
		table.insert(lines, "```")
		table.insert(lines, "")
	end
	table.insert(lines, '```luau button="Cancel"')
	table.insert(lines, 'require("@versions").choose("cancel")')
	table.insert(lines, "```")
	return table.concat(lines, "\n") .. "\n"
end

--- Writes `answer` for Greed to act on, and ends this Greed.
function M.choose(answer: string)
	local info = asked
	if info == nil then
		return
	end
	asked = nil
	greed.fs.write(info.answer, answer)
	greed.quit()
end

-- Shows the page `text` in the focused view, with `keys`, at its first button.
local function show(text: string, keys: { [string]: string })
	local buffer = greed.create_buffer("versions", text, { readonly = true, language = "markdown" })
	buffer:set_line_numbers(false)
	buffer:set_keys(keys)
	greed.view():show(buffer)
	greed.run("versions-next")
end

--- Shows `message`, why Greed can't go on, on a page of its own, for the
--- window, which has no terminal to say it in; closing it ends this Greed.
function M.tell(message: string)
	local text = table.concat({
		"# Greed can't go on",
		"",
		"```text",
		message,
		"```",
		"",
		'```luau button="Close"',
		'require("@greed").quit()',
		"```",
		"",
	}, "\n")
	show(text, { enter = "press-button", esc = "quit-all", q = "quit-all" })
end

--- Shows the page for `info` in the focused view.
function M.ask(info: Info)
	asked = info
	local keys: { [string]: string } = {
		enter = "press-button",
		space = "press-button",
		tab = "versions-next",
		esc = "versions-cancel",
		q = "versions-cancel",
	}
	for i in M.choices(info) do
		keys[tostring(i)] = `versions-{i}`
	end
	show(M.text(info), keys)
end

greed.command({
	name = "versions-next",
	doc = "Go to the next button on the page about another version of Greed",
	run = function(ctx)
		local text = ctx.buffer:text()
		local from = ctx.view:cursor() + 1
		local at = string.find(text, "```luau button=", from + 1, true)
			or string.find(text, "```luau button=", 1, true)
		if at then
			ctx.view:set_cursor(at - 1)
		end
	end,
})

greed.command({
	name = "versions-cancel",
	doc = "Leave the session another version of Greed runs as it is, and stop",
	run = function()
		M.choose("cancel")
	end,
})

for i = 1, 3 do
	greed.command({
		name = `versions-{i}`,
		doc = `Pick choice {i} on the page about another version of Greed`,
		run = function()
			local info = asked
			local choice = info and M.choices(info)[i]
			if choice then
				M.choose(choice.answer)
			end
		end,
	})
end

return M

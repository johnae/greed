-- A session's transcript: a buffer of what you and the agent said and what
-- it did, with a prompt at the bottom to write the next message in. The
-- history above the prompt line is redrawn as the agent goes, so edits
-- there don't last; text below it is yours.
--
--   Claude in ~/src/greed (workspace greed-claude-1)
--
--   ▍ You
--     Fix the off-by-one in the pager
--
--   ▍ Claude
--     Found it in pager.rs.
--     ▸ Edit pager.rs                       done
--       pager.rs: 40 lines → 41
--     ? Allow Run cargo test?   enter to answer
--
--   ── alt-enter sends · ctrl-c stops ──
--   now add a test

local greed = require("@greed")
local session = require("./session")

type Session = session.Session

local M = {}

local PROMPT = "── alt-enter sends · ctrl-c stops ──"

type Style = { from: number, to: number, style: string }

local STATUS_STYLE: { [string]: string } = {
	completed = "diff.plus",
	failed = "diagnostic.error",
	in_progress = "diagnostic.warning",
	pending = "comment",
}

local function shorten(path: string): string
	local home = greed.fs.dirs().home
	return if home and string.sub(path, 1, #home + 1) == home .. "/"
		then "~" .. string.sub(path, #home + 1)
		else path
end

--- The history's text and styles, for `s` as it is now.
function M.history(s: Session): (string, { Style })
	local lines: { string } = {}
	local styles: { Style } = {}
	local at = 0
	local function add(line: string, style: string?, from: number?, to: number?)
		if style then
			table.insert(
				styles,
				{ from = at + (from or 0), to = at + (to or #line), style = style }
			)
		end
		table.insert(lines, line)
		at += #line + 1
	end
	local function body(text: string, style: string?)
		for _, line in string.split(text, "\n") do
			add(if line == "" then "" else "  " .. line, style)
		end
	end
	local where = shorten(s.root)
	local title = `{s.name} in {where}`
	if s.workspace then
		title ..= ` (workspace {s.workspace.name})`
	end
	add(title, "markup.heading")
	local speaker: string? = nil
	for _, entry in s.entries do
		local e = entry :: any
		if e.kind == "user" or e.kind == "agent" then
			local who = if e.kind == "user" then "You" else s.name
			add("")
			add(`▍ {who}`, "markup.heading")
			speaker = e.kind
			body(e.text)
		else
			if speaker ~= "agent" and e.kind ~= "note" then
				add("")
				add(`▍ {s.name}`, "markup.heading")
				speaker = "agent"
			end
			if e.kind == "thought" then
				local first = string.match(e.text, "^%s*([^\n]*)") or ""
				add(`  … {first}`, "comment")
			elseif e.kind == "tool" then
				local tool = e.tool
				local status = string.gsub(tool.status or "pending", "_", " ")
				local line = `  ▸ {tool.title}`
				add(
					`{line}   {status}`,
					STATUS_STYLE[tool.status or "pending"] or "comment",
					#line + 3
				)
				for _, detail in tool.detail do
					add(`    {detail}`, "comment")
				end
			elseif e.kind == "plan" then
				for _, item in e.items do
					local mark = if item.status == "completed"
						then "✓"
						elseif item.status == "in_progress" then "›"
						else "·"
					add(`  {mark} {item.text}`, "comment")
				end
			elseif e.kind == "permission" then
				if e.chosen then
					add(`  ? {e.permission.title}: {e.chosen}`, "comment")
				else
					add(`  ? Allow {e.permission.title}?   enter to answer`, "diagnostic.warning")
				end
			elseif e.kind == "note" then
				add("")
				add(`  {e.text}`, "comment")
			end
		end
	end
	if s.status == "working" then
		add("")
		add(if s.tool then `  working: {s.tool}` else "  working…", "comment")
	end
	add("")
	return table.concat(lines, "\n") .. "\n", styles
end

-- Where the prompt line starts in `buffer`, if it's still there.
local function prompt_at(buffer: greed.Buffer): number?
	local mark = buffer:decorations("acp-prompt")[1]
	return mark and mark.from
end

local function mark_prompt(buffer: greed.Buffer, at: number)
	buffer:decorate("acp-prompt", { { from = at, to = at + #PROMPT, style = "comment" } })
end

--- Redraws the history of `s` in `buffer`, changing only what changed so a
--- reply streaming in only adds to the end.
function M.render(buffer: greed.Buffer, s: Session)
	local history, styles = M.history(s)
	local stop = prompt_at(buffer)
	if stop == nil then
		-- The prompt line went; everything there was is history now.
		buffer:edit(function(e)
			e:replace(0, buffer:len(), history .. PROMPT .. "\n")
		end)
		mark_prompt(buffer, #history)
	else
		local old = buffer:slice(0, stop)
		if old ~= history then
			local same = 0
			local shortest = math.min(#old, #history)
			while
				same < shortest and string.byte(old, same + 1) == string.byte(history, same + 1)
			do
				same += 1
			end
			-- Not inside a character.
			while
				same > 0
				and (string.byte(history, same + 1) or 0) >= 0x80
				and (string.byte(history, same + 1) or 0) < 0xC0
			do
				same -= 1
			end
			buffer:edit(function(e)
				e:replace(same, stop, string.sub(history, same + 1))
			end)
			-- The prompt line now starts where the history ends.
			mark_prompt(buffer, #history)
		end
	end
	buffer:decorate("acp", styles :: any)
end

--- A new transcript buffer for `s`, with an empty prompt.
function M.create(s: Session): greed.Buffer
	local buffer = greed.create_buffer("agent-transcript", "")
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	M.render(buffer, s)
	return buffer
end

--- What's written below the prompt line.
function M.prompt(buffer: greed.Buffer): string
	local stop = prompt_at(buffer)
	if stop == nil then
		return ""
	end
	local start = buffer:line_start(buffer:line_of(stop) + 1)
	if start <= stop then
		return ""
	end
	return buffer:slice(start, buffer:len())
end

--- Empties the prompt.
function M.clear_prompt(buffer: greed.Buffer)
	local stop = prompt_at(buffer)
	if stop == nil then
		return
	end
	local line = buffer:line_of(stop)
	if line + 1 < buffer:line_count() then
		local start = buffer:line_start(line + 1)
		buffer:edit(function(e)
			e:replace(start, buffer:len(), "")
		end)
	end
end

--- Puts the cursor in `view` at the end of the prompt.
function M.focus_prompt(view: greed.View)
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

return M

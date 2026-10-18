-- The `/` menu in notes: typing `/` at the start of a word offers what a
-- note can hold (a todo, a date, a reminder, a repeat, a link, a heading,
-- a table, a tag), and picking one puts it in with places to fill in, as
-- the completion menu puts in a snippet.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")

local M = {}

--- What the menu offers: what to type after `/`, what it puts in (a
--- snippet), and what it is. Dates are worked out as the menu opens.
function M.items(): { { name: string, text: string, detail: string } }
	local today = notes.today()
	local tomorrow = notes.dates.add_days(today, 1)
	return {
		{ name = "todo", text = "- [ ] $0", detail = "a box to tick" },
		{ name = "today", text = today, detail = "today's date" },
		{ name = "tomorrow", text = tomorrow, detail = "tomorrow's date" },
		{ name = "due", text = "due:${1:" .. tomorrow .. "}$0", detail = "when a todo is due" },
		{
			name = "remind",
			text = "remind:${1:" .. tomorrow .. "} ${2:09:00}$0",
			detail = "a reminder",
		},
		{
			name = "every",
			text = "every:${1|monday,tuesday,wednesday,thursday,friday,saturday,sunday,day,weekday,week,month,year|}$0",
			detail = "a todo that comes back",
		},
		{ name = "link", text = "[[${1:note}]]$0", detail = "a link to a note" },
		{ name = "heading", text = "## ${1:Heading}$0", detail = "a heading" },
		{
			name = "table",
			text = "| ${1:Name} | ${2:Value} |\n|---|---|\n| $0 | |",
			detail = "a table",
		},
		{ name = "tag", text = "#${1:tag}$0", detail = "a tag" },
	}
end

-- What the menu offers at the cursor in `view`: the items, after a `/`
-- starting a word in a note.
local function offered(view: greed.View): { core.CompletionItem }?
	local buffer = view:buffer()
	if not notes.is_note(buffer) then
		return nil
	end
	local pos = view:cursor()
	local start = buffer:line_start(buffer:line_of(pos))
	local before = buffer:slice(start, pos)
	-- A `/` starting a word, and what's typed after it.
	local slash = string.match(before, "^()/%a*$") or string.match(before, "%s()/%a*$")
	if slash == nil then
		return nil
	end
	local from = start + (slash :: number) - 1
	local items: { core.CompletionItem } = {}
	for _, item in M.items() do
		table.insert(items, {
			label = `/{item.name}`,
			detail = item.detail,
			text = item.text,
			from = from,
			snippet = true,
		})
	end
	return items
end

-- The menu is the lsp plugin's: `/` offers this while it's loaded, before
-- completing paths.
local function attach()
	require("@lsp").completion.source(offered, { first = true })
end

if table.find(greed.plugin.list(), "lsp") then
	attach()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		attach()
	end
end)

return M

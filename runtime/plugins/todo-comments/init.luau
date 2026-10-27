-- TODO, FIXME and their kind stand out in comments: TODO, HACK and XXX in
-- one color, FIXME and BUG in another, NOTE in a third. Only in comments,
-- by the syntax tree where the language has one (by its comment marker
-- where it doesn't), so a string saying "TODO" stays as it is.
-- `:todo-comments` lists them across the project. `:set todo-comments
-- false` stops picking them out.
--
-- Change the words and their styles from your config:
--
--     require("@todo-comments").words.PERF = "comment.note"

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

greed.option.define({
	name = "todo-comments",
	doc = "Pick out TODO, FIXME and the like in comments",
	default = true,
})

local M = {}

--- The words picked out, and the style of each.
M.words = {
	TODO = "comment.todo",
	HACK = "comment.todo",
	XXX = "comment.todo",
	FIXME = "comment.fixme",
	BUG = "comment.fixme",
	NOTE = "comment.note",
} :: { [string]: string }

--- Whether `pos` in `buffer` is in a comment: in a comment node of its
--- syntax tree, or without one, after its language's comment marker on
--- the line.
function M.in_comment(buffer: greed.Buffer, pos: number): boolean
	local node = buffer:node_at(pos)
	if node then
		return string.find(node.kind, "comment", 1, true) ~= nil
	end
	local token = core.comment.token(buffer:language())
	if token == nil then
		return false
	end
	local start = buffer:line_start(buffer:line_of(pos))
	return string.find(buffer:slice(start, pos), token, 1, true) ~= nil
end

-- Adds a mark to `out` for each word picked out on line `n` of `buffer` in
-- a comment.
local function found(buffer: greed.Buffer, n: number, out: { greed.Mark })
	local text = buffer:line_text(n)
	local start = buffer:line_start(n)
	for at, word, after in string.gmatch(text, "()(%u+)()") do
		local style = M.words[word :: string]
		local before = string.sub(text, (at :: number) - 1, (at :: number) - 1)
		local next = string.sub(text, after :: number, after :: number)
		local whole = not string.match(before, "[%w_]") and not string.match(next, "[%w_]")
		local from = start + (at :: number) - 1
		if style and whole and M.in_comment(buffer, from) then
			table.insert(out, { from = from, to = from + #(word :: string), style = style })
		end
	end
end

local redraw = core.visible.add({
	ns = "todo-comments",
	wants = function(buffer: greed.Buffer): boolean
		return buffer:kind() == "file" and greed.option.get("todo-comments") == true
	end,
	draw = function(buffer: greed.Buffer, first: number, last: number): { greed.Mark }
		local marks: { greed.Mark } = {}
		for n = first, last do
			found(buffer, n, marks)
		end
		return marks
	end,
})

greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "todo-comments" then
		redraw()
	end
end)

-- The words as one regex, for searching the project.
local function pattern(): string
	local words = {}
	for word in M.words do
		table.insert(words, word)
	end
	table.sort(words)
	return `\\b({table.concat(words, "|")})\\b`
end

greed.command({
	name = "todo-comments",
	doc = "List the TODO, FIXME and like comments in the project's files",
	run = function()
		local root = core.project.root()
		local lines, err = greed.fs.grep(pattern(), root)
		if lines == nil then
			greed.echo(`todo-comments: {err}`)
			return
		end
		local items = {}
		for _, line in lines do
			local text = string.gsub(line.text, "^%s+", "")
			table.insert(items, {
				label = `{line.path}:{line.line + 1}`,
				detail = text,
				value = { path = `{root}/{line.path}`, line = line.line },
			})
		end
		if #items == 0 then
			greed.echo("no TODO comments here")
			return
		end
		picker.pick("TODO comments", items, function(item)
			core.file.open_at(item.value.path, item.value.line)
		end)
	end,
})

return M

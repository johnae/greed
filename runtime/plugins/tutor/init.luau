-- The tutor: `:tutor` opens tutor.md, a page to read and edit with the
-- keys of your editing style. It asks which style first, switches to the one
-- picked, and shows each lesson's keys for it, with `<!-- if style=... -->`
-- parts (see the markdown plugin's questions).
--
-- A lesson's exercise is a `practice` block followed by a `want` block, the
-- text it should become. The tutor hides the want block and marks the
-- practice block done once its text matches. The want block's options give
-- each style's keys for it (`vim="w d w"`); the tests press them, so the
-- keys the page teaches are known to work.

local greed = require("@greed")
local markdown = require("@markdown")
local blocks = require("@blocks")

local M = {}

--- An exercise: where its practice block's text is, what it should become,
--- and the keys that do it in each style, from the line's start.
export type Exercise = {
	open: number,
	from: number,
	to: number,
	want: string,
	keys: { [string]: string },
}

-- Each style the page teaches, as its question lists them.
local STYLES = { "vim", "helix", "vscode" }

-- The tutor page, if it's open.
local page: greed.Buffer? = nil

--- The page's text, tutor.md, with the style in use picked.
function M.text(): string
	local dir = greed.plugin.dirs().tutor
	local text = dir and greed.fs.read(`{dir}/tutor.md`) or "# Tutor\n\ntutor.md is missing.\n"
	local now = greed.option.get("editing-style")
	for _, style in STYLES do
		local box = if style == now then "(x)" else "( )"
		text = string.gsub(text, `\n%- %( %) {style}:`, `\n- {box} {style}:`, 1)
	end
	return text
end

-- A code block's text, without its last line break.
local function code_text(buffer: greed.Buffer, from: number, to: number): string
	return (string.gsub(buffer:slice(from, to), "\n$", ""))
end

--- The exercises in `buffer`, in order: each `practice` block with the
--- `want` block right after it.
function M.exercises(buffer: greed.Buffer): { Exercise }
	local code = markdown.structure(buffer).code
	local found: { Exercise } = {}
	for i, block in code do
		local after = code[i + 1]
		if
			block.closed
			and after
			and after.closed
			and string.match(block.info, "^practice%f[%s%z]")
		then
			local lang, keys = blocks.parse.info(after.info)
			if lang == "want" then
				table.insert(found, {
					open = block.open,
					from = block.code_from,
					to = block.code_to,
					want = code_text(buffer, after.code_from, after.code_to),
					keys = keys,
				})
			end
		end
	end
	return found
end

--- Whether `exercise` in `buffer` has become what it should.
function M.done(buffer: greed.Buffer, exercise: Exercise): boolean
	return code_text(buffer, exercise.from, exercise.to) == exercise.want
end

-- Marks each exercise done or not, and hides the want blocks.
local function draw(buffer: greed.Buffer)
	local code = markdown.structure(buffer).code
	local marks: { greed.Mark } = {}
	for i, block in code do
		local before = code[i - 1]
		if
			block.closed
			and string.match(block.info, "^want%f[%s%z]")
			and before
			and string.match(before.info, "^practice")
		then
			table.insert(marks, {
				from = buffer:line_start(block.open),
				to = buffer:line_end(block.open),
				style = "markdown.marker",
				conceal = true,
			})
			table.insert(marks, {
				from = buffer:line_start(block.open),
				to = block.to,
				style = "markdown.marker",
				fold = true,
			})
		end
	end
	for _, exercise in M.exercises(buffer) do
		local done = M.done(buffer, exercise)
		table.insert(marks, {
			from = buffer:line_start(exercise.open),
			to = buffer:line_end(exercise.open),
			style = if done then "diff.plus" else "markdown.marker",
			text = if done then "✓ done" else "edit the lines below",
			eol = true,
		})
	end
	buffer:decorate("tutor", marks)
end

--- Opens the tutor, or goes to it if it's open.
function M.open()
	local open = page
	local shown = if open and open:valid() then open:views()[1] else nil
	if shown then
		shown:focus()
		return
	end
	local buffer = greed.create_buffer("tutor", M.text(), { language = "markdown" })
	page = buffer
	greed.view():show(buffer)
	markdown.refresh(buffer)
	draw(buffer)
end

greed.command({
	name = "tutor",
	doc = "Learn to edit with your editing style's keys, and get around Greed",
	run = M.open,
})

greed.on("buffer.changed", function(event: greed.BufferChanged)
	if event.buffer == page then
		draw(event.buffer)
	end
end)

-- Picking a style on the page switches to it, so its keys work there.
markdown.choices.on_pick(function(buffer, group)
	if buffer ~= page or group.id ~= "style" then
		return
	end
	for _, option in group.options do
		if option.picked and option.value ~= greed.option.get("editing-style") then
			greed.option.set("editing-style", option.value)
		end
	end
end)

return M

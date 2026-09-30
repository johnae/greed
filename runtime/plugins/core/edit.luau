-- Modes and editing commands: insert, append, delete, change, undo.

local kern = require("@kern")
local motions = require("./motions")

local each_range, point = motions.each_range, motions.point

local function from(range)
	return math.min(range.anchor, range.head)
end

local function to(range)
	return math.max(range.anchor, range.head)
end

-- Everything typed in one insert session, plus the delete that `change` does
-- before it, is undone as one step.
local function enter_insert()
	kern.history.start_group()
	kern.mode.set("insert")
end

kern.command({
	name = "normal-mode",
	doc = "Switch to normal mode",
	run = function()
		kern.history.end_group()
		kern.mode.set("normal")
	end,
})

kern.command({
	name = "insert-mode",
	doc = "Insert before each selection",
	run = function(ctx)
		each_range(ctx, function(_, range)
			return point(from(range))
		end)
		enter_insert()
	end,
})

kern.command({
	name = "append-mode",
	doc = "Insert after each selection",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			if range.anchor ~= range.head then
				return point(to(range))
			end
			return point(math.min(buffer:len(), buffer:next_char(range.head)))
		end)
		enter_insert()
	end,
})

-- Inserts `text` at every cursor; cursors end up after it.
local function insert_at_heads(ctx, text: string)
	ctx.buffer:edit(ctx.view:selection(), function(e, range)
		e:insert(range.head, text)
	end)
end

kern.command({
	name = "insert-char",
	doc = "Insert the typed character at each cursor",
	run = function(ctx)
		if ctx.char then
			insert_at_heads(ctx, ctx.char)
		end
	end,
})

kern.command({
	name = "insert-newline",
	doc = "Insert a line break at each cursor",
	run = function(ctx)
		insert_at_heads(ctx, "\n")
	end,
})

kern.command({
	name = "delete-back",
	doc = "Delete the character before each cursor",
	run = function(ctx)
		ctx.buffer:edit(ctx.view:selection(), function(e, range)
			if range.head > 0 then
				e:delete(ctx.buffer:prev_char(range.head), range.head)
			end
		end)
	end,
})

-- Deletes each selection, or the character under each cursor.
local function delete_selections(ctx)
	ctx.buffer:edit(ctx.view:selection(), function(e, range)
		if range.anchor ~= range.head then
			e:delete(from(range), to(range))
		elseif range.head < ctx.buffer:len() then
			e:delete(range.head, ctx.buffer:next_char(range.head))
		end
	end)
end

kern.command({
	name = "delete",
	doc = "Delete each selection",
	run = delete_selections,
})

kern.command({
	name = "change",
	doc = "Delete each selection and switch to insert mode",
	run = function(ctx)
		kern.history.start_group()
		delete_selections(ctx)
		enter_insert()
	end,
})

kern.command({
	name = "open-below",
	doc = "Open a new line below each cursor and insert there",
	run = function(ctx)
		kern.history.start_group()
		each_range(ctx, function(buffer, range)
			return point(buffer:line_end(buffer:line_of(range.head)))
		end)
		insert_at_heads(ctx, "\n")
		enter_insert()
	end,
})

kern.command({
	name = "open-above",
	doc = "Open a new line above each cursor and insert there",
	run = function(ctx)
		kern.history.start_group()
		each_range(ctx, function(buffer, range)
			return point(buffer:line_start(buffer:line_of(range.head)))
		end)
		insert_at_heads(ctx, "\n")
		each_range(ctx, function(buffer, range)
			return point(buffer:prev_char(range.head))
		end)
		enter_insert()
	end,
})

kern.command({
	name = "undo",
	doc = "Undo the last change",
	run = function(ctx)
		ctx.view:undo()
	end,
})

kern.command({
	name = "redo",
	doc = "Redo the last undone change",
	run = function(ctx)
		ctx.view:redo()
	end,
})

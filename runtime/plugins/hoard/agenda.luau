-- The agenda as a note: what's due, written as queries (`notes` blocks)
-- that keep themselves up to date. Hoard makes it the first time it's
-- opened; from then on it's yours to change, and any of its blocks can
-- be copied into another note.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")

local M = {}

--- The note's name.
M.NAME = "agenda"

--- What the note starts as.
M.TEXT = [[
# Agenda

What's due, as queries that keep up as your notes change. Change them,
or copy one into any note. Enter on a table's top border opens it, to
tick a todo off.

## Overdue

```notes
is:todo is:overdue sort:due
```

## Today

```notes
is:today sort:due
```

## The next seven days

```notes
is:todo is:open due:+1d..+7d sort:due
```

## Waiting a long time

```notes
is:waiting sort:date
```

## Habits

```notes
is:habit sort:title
```
]]

--- Opens the agenda note, making it first if there isn't one.
function M.open()
	local path = notes.path(M.NAME)
	if greed.fs.stat(path) == nil then
		local ok, err = greed.fs.write(path, M.TEXT)
		if not ok then
			greed.echo(`can't make the agenda: {err}`)
			return
		end
	end
	core.file.open(path)
end

greed.command({
	name = "hoard-agenda",
	doc = "Open the agenda note: what's due, as queries you can change",
	run = function()
		M.open()
	end,
})

return M

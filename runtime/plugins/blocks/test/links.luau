local test = require("@greed/test")
local greed = require("@greed")
local blocks = require("@blocks")

local links = blocks.links

-- `text` open as a Markdown file of its own; its buffer.
local function open(t: test.TestContext, text: string): greed.Buffer
	local dir = t:tempdir({ ["doc.md"] = text })
	greed.open(`{dir}/doc.md`)
	return greed.view():buffer()
end

-- Presses the first button in `buffer`, answering `key` when asked; the
-- block it ran, if it ran, and what it asked.
local function press(t: test.TestContext, buffer: greed.Buffer, key: string?): (any, string?)
	local line = buffer:line_of(string.find(buffer:text(), "](run:", 1, true) :: number)
	local button = links.buttons(buffer:line_text(line))[1]
	local ran: any = nil
	local done = false
	greed.spawn(function()
		ran = links.press(buffer, button)
		done = true
	end)
	local asked: string? = nil
	if key then
		t:wait_for(function()
			local said = t:messages()
			asked = said[#said]
			return string.find(asked or "", "y yes, a always", 1, true) ~= nil
		end)
		t:keys(key)
	end
	t:wait_for(function()
		return done
	end)
	return ran, asked
end

test("a command button runs its command, a value in it as one argument", function(t)
	local buffer = open(t, "Who: [x'; echo pwned](field:who)\n\n[Say](run:echo hello {{ who }})\n")
	local rows = table.concat(t:draw(60, 10), "\n")
	assert(string.find(rows, "▶ Say", 1, true), rows)
	-- Asked first, the command as it runs shown; a lets it run from now on.
	local block = assert(press(t, buffer, "a"), "it ran")
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(block.output == "hello x'; echo pwned\n", block.output)
	assert(press(t, buffer, nil) ~= nil, "as it was let run, it runs without asking")
end)

test("a command changed since you let it run asks again; n runs nothing", function(t)
	local buffer = open(t, "[Say](run:echo one)\n")
	press(t, buffer, "a")
	buffer:edit(function(e)
		e:replace(0, buffer:len(), "[Say](run:echo two)\n")
	end)
	local ran, asked = press(t, buffer, "n")
	assert(ran == nil, "nothing ran")
	assert(string.find(asked or "", "run `echo two`", 1, true), asked)
end)

test("a value that goes wrong runs nothing and says why", function(t)
	local buffer = open(t, "[Go](run:echo {{ missing + 1 }})\n")
	assert(press(t, buffer, nil) == nil, "nothing ran")
	local said = t:messages()
	assert(string.find(said[#said] or "", "`missing` is empty", 1, true), said[#said])
end)

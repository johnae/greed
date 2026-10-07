-- Following Markdown links: `[text](#heading)` to a heading in the file,
-- `[text](other.md#heading)` to another file, and `[text](https://...)`
-- to a web page, opened with the link-opener option.

local greed = require("@greed")
local structure = require("./structure")
local core = require("@core")

local M = {}

-- `%20` and the like as the characters they stand for.
local function decode(text: string): string
	return (
		string.gsub(text, "%%(%x%x)", function(hex: string)
			return string.char(tonumber(hex, 16) :: number)
		end)
	)
end

--- The folder `buffer`'s file is in, if it has one.
function M.dir(buffer: greed.Buffer): string?
	local path = buffer:path()
	return if path then string.match(path, "^(.*)/[^/]*$") else nil
end

-- Whether `target` starts with a scheme, like https:.
local function has_scheme(target: string): boolean
	return string.match(target, "^%a[%w+.-]*:") ~= nil
end

--- The path a link's `target` names, from `buffer`'s folder, without any
--- `#heading`; nil for web addresses and for targets with no path.
function M.path(buffer: greed.Buffer, target: string): string?
	if has_scheme(target) then
		return nil
	end
	local path = decode(string.match(target, "^[^#?]*") or "")
	if path == "" then
		return nil
	elseif string.sub(path, 1, 1) == "/" then
		return path
	end
	local dir = M.dir(buffer)
	return if dir then `{dir}/{path}` else nil
end

--- The target of the link `[text](target)` over `pos`, and where in the
--- buffer the target starts.
function M.at(buffer: greed.Buffer, pos: number): (string?, number?)
	for _, link in structure.of(buffer).links do
		if pos >= link.from and pos < link.to then
			return link.target, link.target_from
		end
	end
	return nil, nil
end

--- A heading's anchor, as GitHub makes them: lower case, punctuation
--- dropped, spaces as dashes.
function M.slug(heading: string): string
	local words = string.gsub(string.lower(heading), "[^%w%s%-_]", "")
	return (string.gsub(words, "%s", "-"))
end

--- The line of the heading in `buffer` whose anchor is `anchor`.
function M.heading(buffer: greed.Buffer, anchor: string): number?
	local want = string.lower(decode(anchor))
	for _, heading in structure.of(buffer).headings do
		if M.slug(heading.text) == want then
			return heading.line
		end
	end
	return nil
end

--- Puts the cursor on the heading `anchor` names in the view's buffer, at
--- the top of the view. False if there's no such heading.
function M.jump(view: greed.View, anchor: string): boolean
	local buffer = view:buffer()
	local line = M.heading(buffer, anchor)
	if line == nil then
		return false
	end
	local at = buffer:line_start(line)
	view:set_cursor(at)
	view:set_scroll(line)
	return true
end

--- Follows `target`, a link's target in the view's buffer. Returns the
--- buffer it opened, if it opened one.
function M.follow(view: greed.View, target: string): greed.Buffer?
	local buffer = view:buffer()
	local anchor = string.match(target, "#(.*)$")
	if string.sub(target, 1, 1) == "#" then
		if not M.jump(view, anchor or "") then
			greed.echo(`no heading {target}`)
		end
		return nil
	end
	-- A web page, or anything else with a scheme.
	if has_scheme(target) then
		core.file.open_link(target)
		return nil
	end
	local path = M.path(buffer, target)
	if path == nil then
		greed.echo(`can't open {target}`)
		return nil
	end
	if greed.fs.stat(path) == nil then
		greed.echo(`no file {path}`)
		return nil
	end
	core.file.open(path)
	if anchor and anchor ~= "" then
		M.jump(greed.view(), anchor)
	end
	return greed.view():buffer()
end

return M

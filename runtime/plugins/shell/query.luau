-- What's typed in the shell's filters (`/` on a block's lines or a table's
-- rows) read as a query, as `core.query` reads any: words, `key=value`,
-- `level>=warn`, `msg~timeout`, `-word`, `OR`. Two things are the shell's
-- own: a filter starting with `/` is a regex for the lines, and a word
-- starting with `.` (`.status.conditions`) keeps that section of nested
-- text. Words mind case as `shell-filter-search-case` says.

local core = require("@core")

local M = {}

--- A filter read: a `regex`, or a `query` (nil for none) with the
--- `section` it keeps; whether words mind `case`; and `problem`, what's
--- wrong with what's typed (then it filters nothing yet).
export type Filter = {
	regex: string?,
	query: core.QueryNode?,
	section: string,
	case: boolean,
	problem: string?,
}

-- Whether words typed as `text` mind case, as `shell-filter-search-case`
-- says ("smart": only with a capital letter in them).
local function minds_case(text: string): boolean
	local case = core.search.case("shell-filter")
	return case == "match" or (case == "smart" and string.find(text, "%u") ~= nil)
end

-- Whether `node` is a `.a.b` section word.
local function is_section(node: core.QueryNode): boolean
	return node.kind == "word" and not node.phrase and string.match(node.text or "", "^%.%a") ~= nil
end

--- What `text`, typed in a shell filter, keeps.
function M.read(text: string): Filter
	if string.sub(text, 1, 1) == "/" then
		local pattern = string.sub(text, 2)
		return { regex = pattern, section = "", case = minds_case(pattern) }
	end
	local parsed = core.query.parse(text)
	if not parsed.ok then
		for _, p in parsed.problems do
			if not p.hint then
				return { section = "", case = false, problem = p.message }
			end
		end
	end
	-- A top-level word starting with `.` is the section; the rest is the
	-- query.
	local section = ""
	local query = parsed.query
	if query and is_section(query) then
		section = string.sub(query.text :: string, 2)
		query = nil
	elseif query and query.kind == "and" then
		local kept: { core.QueryNode } = {}
		for _, item in query.items :: { core.QueryNode } do
			if is_section(item) then
				section = string.sub(item.text :: string, 2)
			else
				table.insert(kept, item)
			end
		end
		query = if #kept == 0
			then nil
			elseif #kept == 1 then kept[1]
			else core.query.join("and", kept, query.at)
	end
	return { query = query, section = section, case = minds_case(text) }
end

--- What `view:set_filter` and `buffer:kept_lines` take to keep what
--- `filter` does; nil for a filter with a problem.
function M.options(filter: Filter): { [string]: any }?
	if filter.problem then
		return nil
	end
	return {
		regex = filter.regex ~= nil,
		query = filter.query,
		section = filter.section,
		case = filter.case,
	}
end

return M

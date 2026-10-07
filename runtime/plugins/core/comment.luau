-- Line comments: ctrl-c comments the lines of each selection, or takes the
-- comments away if every line already has one. What starts a comment comes
-- from the buffer's language; the languages plugin fills it in.

local greed = require("@greed")
local motions = require("./motions")
local registry = require("./registry")

local tokens: { [string]: string? } = {}

local M = {}

--- Sets what starts a line comment in `language`, e.g. "//".
function M.set(language: string, token: string?)
	if token then
		greed.plugin.tie(registry.set(tokens, language, token))
	else
		tokens[language] = nil
	end
end

--- What starts a line comment in `language`, if Greed knows.
function M.token(language: string?): string?
	return if language then tokens[language] else nil
end

greed.command({
	name = "toggle-comment",
	doc = "Comment the lines of each selection, or uncomment them if they all are",
	run = function(ctx)
		local buffer = ctx.buffer
		local token = M.token(buffer:language())
		if token == nil then
			greed.echo("no line comment for this language")
			return
		end
		-- Each non-blank line: where it starts, its text and its indent.
		local lines: { { start: number, text: string, lead: number } } = {}
		local indent = math.huge
		local commented = true
		for _, line in motions.selected_lines(ctx) do
			local start = buffer:line_start(line)
			local text = buffer:line_text(line)
			local lead = #(string.match(text, "^[ \t]*") :: string)
			if lead < #text then
				table.insert(lines, { start = start, text = text, lead = lead })
				indent = math.min(indent, lead)
				if string.sub(text, lead + 1, lead + #token) ~= token then
					commented = false
				end
			end
		end
		if #lines == 0 then
			return
		end
		if commented then
			buffer:edit(function(e)
				for _, l in lines do
					local take = #token
					if string.sub(l.text, l.lead + #token + 1, l.lead + #token + 1) == " " then
						take += 1
					end
					local at = l.start + l.lead
					e:delete(at, at + take)
				end
			end)
			return
		end
		local points = {}
		for _, l in lines do
			table.insert(points, l.start + indent)
		end
		motions.insert_at(ctx, points, token .. " ")
	end,
})

return M

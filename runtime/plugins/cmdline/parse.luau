-- Splitting a command line into words.

export type Parsed = {
	--- The command as typed, without a trailing "!".
	name: string,
	--- Whether the command ended in "!", as in `:q!`.
	force: boolean,
	args: { string },
}

local M = {}

-- Splits `line` into words at whitespace. Quotes ("..." or '...') keep
-- spaces inside a word, and a backslash takes the next character as is.
function M.words(line: string): { string }
	local words = {}
	local word: string? = nil
	local quote: string? = nil
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == "\\" and i < #line then
			i += 1
			word = (word or "") .. string.sub(line, i, i)
		elseif quote then
			if c == quote then
				quote = nil
			else
				word = (word or "") .. c
			end
		elseif c == '"' or c == "'" then
			quote = c
			word = word or ""
		elseif string.match(c, "%s") then
			if word then
				table.insert(words, word)
				word = nil
			end
		else
			word = (word or "") .. c
		end
		i += 1
	end
	if word then
		table.insert(words, word)
	end
	return words
end

-- Quotes `word` if it needs it to come back from `words` unchanged.
function M.quote(word: string): string
	if word ~= "" and not string.find(word, "[%s\"'\\]") then
		return word
	end
	return '"' .. string.gsub(word, '["\\]', "\\%0") .. '"'
end

-- The command and its arguments, or nil for a blank line.
function M.parse(line: string): Parsed?
	local words = M.words(line)
	local first = table.remove(words, 1)
	if first == nil then
		return nil
	end
	local force = #first > 1 and string.sub(first, -1) == "!"
	return {
		name = if force then string.sub(first, 1, -2) else first,
		force = force,
		args = words,
	}
end

return M

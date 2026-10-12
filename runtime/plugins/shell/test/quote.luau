local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

local quote = shell.parse.quote

test("text is quoted as each shell reads one word", function()
	assert(quote("plain-word.txt") == "plain-word.txt", "nothing to quote")
	assert(quote("two words") == "'two words'")
	assert(quote("it's") == "'it'\\''s'", quote("it's"))
	-- nu's single quotes can't hold one, so double quotes, $ left alone.
	assert(quote("two words", "nu") == "'two words'")
	assert(
		quote([[it's "$HOME" \ (x)]], "nu") == [["it's \"$HOME\" \\ (x)"]],
		quote([[it's "$HOME" \ (x)]], "nu")
	)
	-- fish's single quotes take backslashes as escapes, its double quotes $.
	assert(quote("two words", "fish") == "'two words'")
	assert(quote([[it's $HOME \]], "fish") == [["it's \$HOME \\"]], quote([[it's $HOME \]], "fish"))
end)

test("the Greed shell reads each shell's quoting as the one word it was", function()
	for _, program in { "sh", "nu", "fish" } do
		for _, text in { "two words", "it's", [[say "hi" \ there]] } do
			local words = shell.parse.words(`echo {quote(text, program)}`)
			assert(words and words[2] == text, `{program}: {text}`)
		end
	end
end)

test("sh gets back what was quoted for it", function()
	local text = [[it's "$HOME" `x` \ $(y)]]
	local ran = assert(greed.process.run({ "sh", "-c", `printf %s {quote(text)}` }))
	assert(ran.stdout == text, ran.stdout)
end)

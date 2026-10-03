-- Helix's own word motion tests (helix-core/src/movement.rs), run against
-- core's port: each case is a count, a range before and the range after,
-- as anchor and head. Samples with multibyte characters are left out, since
-- Helix counts characters and Kern bytes.

local test = require("@kern/test")
local kern = require("@kern")
local words = require("@core").words

local CASES: { [string]: { any } } = {
	["next-word-start"] = {
		{
			"Basic forward motion stops at the first space",
			{ { 1, { 0, 0 }, { 0, 6 } } },
		},
		{
			" Starting from a boundary advances the anchor",
			{ { 1, { 0, 0 }, { 1, 10 } } },
		},
		{
			"Long       whitespace gap is bridged by the head",
			{ { 1, { 0, 0 }, { 0, 11 } } },
		},
		{
			"Previous anchor is irrelevant for forward motions",
			{ { 1, { 12, 0 }, { 0, 9 } } },
		},
		{
			"    Starting from whitespace moves to last space in sequence",
			{ { 1, { 0, 0 }, { 0, 4 } } },
		},
		{
			"Starting from mid-word leaves anchor at start position and moves head",
			{ { 1, { 3, 3 }, { 3, 9 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 0 }, { 0, 29 } } },
		},
		{
			"Jumping\n    into starting whitespace selects the spaces before 'into'",
			{ { 1, { 0, 7 }, { 8, 12 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are considered 'words' for the purposes of word motion",
			{
				{ 1, { 0, 0 }, { 0, 12 } },
				{ 1, { 0, 12 }, { 12, 15 } },
				{ 1, { 12, 15 }, { 15, 18 } },
			},
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 0 }, { 0, 6 } },
				{ 1, { 0, 6 }, { 6, 10 } },
			},
		},
		{
			".._.._ punctuation is not joined by underscores into a single block",
			{ { 1, { 0, 0 }, { 0, 2 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{
				{ 1, { 0, 0 }, { 0, 8 } },
				{ 1, { 0, 8 }, { 10, 14 } },
			},
		},
		{
			"Jumping\n\n\n\n\n\n   from newlines to whitespace selects whitespace.",
			{
				{ 1, { 0, 9 }, { 13, 16 } },
			},
		},
		{
			"A failed motion does not modify the range",
			{
				{ 3, { 37, 41 }, { 37, 41 } },
			},
		},
		{
			"oh oh oh two character words!",
			{
				{ 1, { 0, 0 }, { 0, 3 } },
				{ 1, { 0, 3 }, { 3, 6 } },
				{ 1, { 0, 2 }, { 1, 3 } },
			},
		},
		{
			"Multiple motions at once resolve correctly",
			{
				{ 3, { 0, 0 }, { 17, 20 } },
			},
		},
		{
			"Excessive motions are performed partially",
			{
				{ 999, { 0, 0 }, { 32, 41 } },
			},
		},
		{
			"", -- Edge case of moving forward in empty string
			{
				{ 1, { 0, 0 }, { 0, 0 } },
			},
		},
		{
			"\n\n\n\n\n", -- Edge case of moving forward in all newlines
			{
				{ 1, { 0, 0 }, { 5, 5 } },
			},
		},
		{
			"\n   \n   \n Jumping through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 0 }, { 1, 4 } },
				{ 1, { 1, 4 }, { 5, 8 } },
			},
		},
		{
			"ヒーリクス multibyte characters behave as normal characters",
			{
				{ 1, { 0, 0 }, { 0, 6 } },
			},
		},
	},
	["next-long-word-start"] = {
		{
			"Basic forward motion stops at the first space",
			{ { 1, { 0, 0 }, { 0, 6 } } },
		},
		{
			" Starting from a boundary advances the anchor",
			{ { 1, { 0, 0 }, { 1, 10 } } },
		},
		{
			"Long       whitespace gap is bridged by the head",
			{ { 1, { 0, 0 }, { 0, 11 } } },
		},
		{
			"Previous anchor is irrelevant for forward motions",
			{ { 1, { 12, 0 }, { 0, 9 } } },
		},
		{
			"    Starting from whitespace moves to last space in sequence",
			{ { 1, { 0, 0 }, { 0, 4 } } },
		},
		{
			"Starting from mid-word leaves anchor at start position and moves head",
			{ { 1, { 3, 3 }, { 3, 9 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 0 }, { 0, 29 } } },
		},
		{
			"Jumping\n    into starting whitespace selects the spaces before 'into'",
			{ { 1, { 0, 7 }, { 8, 12 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are not treated any differently than alphanumerics",
			{
				{ 1, { 0, 0 }, { 0, 33 } },
			},
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 0 }, { 0, 6 } },
				{ 1, { 0, 6 }, { 6, 10 } },
			},
		},
		{
			".._.._ punctuation is joined by underscores into a single word, as it behaves like alphanumerics",
			{ { 1, { 0, 0 }, { 0, 7 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{
				{ 1, { 0, 0 }, { 0, 8 } },
				{ 1, { 0, 8 }, { 10, 14 } },
			},
		},
		{
			"Jumping\n\n\n\n\n\n   from newlines to whitespace selects whitespace.",
			{
				{ 1, { 0, 9 }, { 13, 16 } },
			},
		},
		{
			"A failed motion does not modify the range",
			{
				{ 3, { 37, 41 }, { 37, 41 } },
			},
		},
		{
			"oh oh oh two character words!",
			{
				{ 1, { 0, 0 }, { 0, 3 } },
				{ 1, { 0, 3 }, { 3, 6 } },
				{ 1, { 0, 1 }, { 0, 3 } },
			},
		},
		{
			"Multiple motions at once resolve correctly",
			{
				{ 3, { 0, 0 }, { 17, 20 } },
			},
		},
		{
			"Excessive motions are performed partially",
			{
				{ 999, { 0, 0 }, { 32, 41 } },
			},
		},
		{
			"", -- Edge case of moving forward in empty string
			{
				{ 1, { 0, 0 }, { 0, 0 } },
			},
		},
		{
			"\n\n\n\n\n", -- Edge case of moving forward in all newlines
			{
				{ 1, { 0, 0 }, { 5, 5 } },
			},
		},
		{
			"\n   \n   \n Jumping through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 0 }, { 1, 4 } },
				{ 1, { 1, 4 }, { 5, 8 } },
			},
		},
		{
			"ヒー..リクス multibyte characters behave as normal characters, including their interaction with punctuation",
			{
				{ 1, { 0, 0 }, { 0, 8 } },
			},
		},
	},
	["prev-word-start"] = {
		{
			"Basic backward motion from the middle of a word",
			{ { 1, { 3, 3 }, { 4, 0 } } },
		},

		{
			"    Jump to start of a word preceded by whitespace",
			{ { 1, { 5, 5 }, { 6, 4 } } },
		},
		{
			"    Jump to start of line from start of word preceded by whitespace",
			{ { 1, { 4, 4 }, { 4, 0 } } },
		},
		{
			"Previous anchor is irrelevant for backward motions",
			{ { 1, { 12, 5 }, { 6, 0 } } },
		},
		{
			"    Starting from whitespace moves to first space in sequence",
			{ { 1, { 0, 4 }, { 4, 0 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 20 }, { 20, 0 } } },
		},
		{
			"Jumping\n    \nback through a newline selects whitespace",
			{ { 1, { 0, 13 }, { 12, 8 } } },
		},
		{
			"Jumping to start of word from the end selects the word",
			{ { 1, { 6, 7 }, { 7, 0 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are considered 'words' for the purposes of word motion",
			{
				{ 1, { 29, 30 }, { 30, 21 } },
				{ 1, { 30, 21 }, { 21, 18 } },
				{ 1, { 21, 18 }, { 18, 15 } },
			},
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 10 }, { 10, 6 } },
				{ 1, { 10, 6 }, { 6, 0 } },
			},
		},
		{
			".._.._ punctuation is not joined by underscores into a single block",
			{ { 1, { 0, 6 }, { 5, 3 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{
				{ 1, { 0, 10 }, { 8, 0 } },
			},
		},
		{
			"Jumping    \n\n\n\n\nback from within a newline group selects previous block",
			{
				{ 1, { 0, 13 }, { 11, 0 } },
			},
		},
		{
			"Failed motions do not modify the range",
			{
				{ 0, { 3, 0 }, { 3, 0 } },
			},
		},
		{
			"Multiple motions at once resolve correctly",
			{
				{ 3, { 18, 18 }, { 9, 0 } },
			},
		},
		{
			"Excessive motions are performed partially",
			{
				{ 999, { 40, 40 }, { 10, 0 } },
			},
		},
		{
			"", -- Edge case of moving backwards in empty string
			{
				{ 1, { 0, 0 }, { 0, 0 } },
			},
		},
		{
			"\n\n\n\n\n", -- Edge case of moving backwards in all newlines
			{
				{ 1, { 5, 5 }, { 0, 0 } },
			},
		},
		{
			"   \n   \nJumping back through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 8 }, { 7, 4 } },
				{ 1, { 7, 4 }, { 3, 0 } },
			},
		},
		{
			"ヒーリクス multibyte characters behave as normal characters",
			{
				{ 1, { 0, 6 }, { 6, 0 } },
			},
		},
	},
	["prev-long-word-start"] = {
		{
			"Basic backward motion from the middle of a word",
			{ { 1, { 3, 3 }, { 4, 0 } } },
		},

		{
			"    Jump to start of a word preceded by whitespace",
			{ { 1, { 5, 5 }, { 6, 4 } } },
		},
		{
			"    Jump to start of line from start of word preceded by whitespace",
			{ { 1, { 3, 4 }, { 4, 0 } } },
		},
		{
			"Previous anchor is irrelevant for backward motions",
			{ { 1, { 12, 5 }, { 6, 0 } } },
		},
		{
			"    Starting from whitespace moves to first space in sequence",
			{ { 1, { 0, 4 }, { 4, 0 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 20 }, { 20, 0 } } },
		},
		{
			"Jumping\n    \nback through a newline selects whitespace",
			{ { 1, { 0, 13 }, { 12, 8 } } },
		},
		{
			"Jumping to start of word from the end selects the word",
			{ { 1, { 6, 7 }, { 7, 0 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are treated exactly the same",
			{ { 1, { 29, 30 }, { 30, 0 } } },
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 10 }, { 10, 6 } },
				{ 1, { 10, 6 }, { 6, 0 } },
			},
		},
		{
			".._.._ punctuation is joined by underscores into a single block",
			{ { 1, { 0, 6 }, { 6, 0 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{ { 1, { 0, 10 }, { 8, 0 } } },
		},
		{
			"Jumping    \n\n\n\n\nback from within a newline group selects previous block",
			{ { 1, { 0, 13 }, { 11, 0 } } },
		},
		{
			"Failed motions do not modify the range",
			{ { 0, { 3, 0 }, { 3, 0 } } },
		},
		{
			"Multiple motions at once resolve correctly",
			{ { 3, { 19, 19 }, { 9, 0 } } },
		},
		{
			"Excessive motions are performed partially",
			{ { 999, { 40, 40 }, { 10, 0 } } },
		},
		{
			"", -- Edge case of moving backwards in empty string
			{ { 1, { 0, 0 }, { 0, 0 } } },
		},
		{
			"\n\n\n\n\n", -- Edge case of moving backwards in all newlines
			{ { 1, { 5, 5 }, { 0, 0 } } },
		},
		{
			"   \n   \nJumping back through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 8 }, { 7, 4 } },
				{ 1, { 7, 4 }, { 3, 0 } },
			},
		},
		{
			"ヒーリ..クス multibyte characters behave as normal characters, including when interacting with punctuation",
			{
				{ 1, { 0, 8 }, { 8, 0 } },
			},
		},
	},
	["next-word-end"] = {
		{
			"Basic forward motion from the start of a word to the end of it",
			{ { 1, { 0, 0 }, { 0, 5 } } },
		},
		{
			"Basic forward motion from the end of a word to the end of the next",
			{ { 1, { 0, 5 }, { 5, 13 } } },
		},
		{
			"Basic forward motion from the middle of a word to the end of it",
			{ { 1, { 2, 2 }, { 2, 5 } } },
		},
		{
			"    Jumping to end of a word preceded by whitespace",
			{ { 1, { 0, 0 }, { 0, 11 } } },
		},

		{
			"Previous anchor is irrelevant for end of word motion",
			{ { 1, { 12, 2 }, { 2, 8 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 0 }, { 0, 28 } } },
		},
		{
			"Jumping\n    into starting whitespace selects up to the end of next word",
			{ { 1, { 0, 7 }, { 8, 16 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are considered 'words' for the purposes of word motion",
			{
				{ 1, { 0, 0 }, { 0, 12 } },
				{ 1, { 0, 12 }, { 12, 15 } },
				{ 1, { 12, 15 }, { 15, 18 } },
			},
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 0 }, { 0, 3 } },
				{ 1, { 0, 3 }, { 3, 9 } },
			},
		},
		{
			".._.._ punctuation is not joined by underscores into a single block",
			{ { 1, { 0, 0 }, { 0, 2 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{
				{ 1, { 0, 0 }, { 0, 8 } },
				{ 1, { 0, 8 }, { 10, 13 } },
			},
		},
		{
			"Jumping\n\n\n\n\n\n   from newlines to whitespace selects to end of next word.",
			{
				{ 1, { 0, 8 }, { 13, 20 } },
			},
		},
		{
			"A failed motion does not modify the range",
			{
				{ 3, { 37, 41 }, { 37, 41 } },
			},
		},
		{
			"Multiple motions at once resolve correctly",
			{
				{ 3, { 0, 0 }, { 16, 19 } },
			},
		},
		{
			"Excessive motions are performed partially",
			{
				{ 999, { 0, 0 }, { 31, 41 } },
			},
		},
		{
			"", -- Edge case of moving forward in empty string
			{
				{ 1, { 0, 0 }, { 0, 0 } },
			},
		},
		{
			"\n\n\n\n\n", -- Edge case of moving forward in all newlines
			{
				{ 1, { 0, 0 }, { 5, 5 } },
			},
		},
		{
			"\n   \n   \n Jumping through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 0 }, { 1, 4 } },
				{ 1, { 1, 4 }, { 5, 8 } },
			},
		},
		{
			"ヒーリクス multibyte characters behave as normal characters",
			{
				{ 1, { 0, 0 }, { 0, 5 } },
			},
		},
	},
	["next-long-word-end"] = {
		{
			"Basic forward motion from the start of a word to the end of it",
			{ { 1, { 0, 0 }, { 0, 5 } } },
		},
		{
			"Basic forward motion from the end of a word to the end of the next",
			{ { 1, { 0, 5 }, { 5, 13 } } },
		},
		{
			"Basic forward motion from the middle of a word to the end of it",
			{ { 1, { 2, 2 }, { 2, 5 } } },
		},
		{
			"    Jumping to end of a word preceded by whitespace",
			{ { 1, { 0, 0 }, { 0, 11 } } },
		},

		{
			"Previous anchor is irrelevant for end of word motion",
			{ { 1, { 12, 2 }, { 2, 8 } } },
		},
		{
			"Identifiers_with_underscores are considered a single word",
			{ { 1, { 0, 0 }, { 0, 28 } } },
		},
		{
			"Jumping\n    into starting whitespace selects up to the end of next word",
			{ { 1, { 0, 7 }, { 8, 16 } } },
		},
		{
			"alphanumeric.!,and.?=punctuation are treated the same way",
			{
				{ 1, { 0, 0 }, { 0, 32 } },
			},
		},
		{
			"...   ... punctuation and spaces behave as expected",
			{
				{ 1, { 0, 0 }, { 0, 3 } },
				{ 1, { 0, 3 }, { 3, 9 } },
			},
		},
		{
			".._.._ punctuation is joined by underscores into a single block",
			{ { 1, { 0, 0 }, { 0, 6 } } },
		},
		{
			"Newlines\n\nare bridged seamlessly.",
			{
				{ 1, { 0, 0 }, { 0, 8 } },
				{ 1, { 0, 8 }, { 10, 13 } },
			},
		},
		{
			"Jumping\n\n\n\n\n\n   from newlines to whitespace selects to end of next word.",
			{
				{ 1, { 0, 9 }, { 13, 20 } },
			},
		},
		{
			"A failed motion does not modify the range",
			{
				{ 3, { 37, 41 }, { 37, 41 } },
			},
		},
		{
			"Multiple motions at once resolve correctly",
			{
				{ 3, { 0, 0 }, { 16, 19 } },
			},
		},
		{
			"Excessive motions are performed partially",
			{
				{ 999, { 0, 0 }, { 31, 41 } },
			},
		},
		{
			"", -- Edge case of moving forward in empty string
			{
				{ 1, { 0, 0 }, { 0, 0 } },
			},
		},
		{
			"\n\n\n\n\n", -- Edge case of moving forward in all newlines
			{
				{ 1, { 0, 0 }, { 5, 5 } },
			},
		},
		{
			"\n   \n   \n Jumping through alternated space blocks and newlines selects the space blocks",
			{
				{ 1, { 0, 0 }, { 1, 4 } },
				{ 1, { 1, 4 }, { 5, 8 } },
			},
		},
		{
			"ヒーリ..クス multibyte characters behave as normal characters, including  when they interact with punctuation",
			{
				{ 1, { 0, 0 }, { 0, 7 } },
			},
		},
	},
}

for target, cases in CASES do
	test(`{target} moves as in Helix`, function()
		for _, case in cases do
			local sample, steps = case[1] :: string, case[2] :: { any }
			if string.find(sample, "[\128-\255]") then
				continue
			end
			local buffer = kern.create_buffer("scratch", sample)
			for _, s in steps do
				local count, from, want = s[1], s[2], s[3]
				local got =
					words.move(buffer, { anchor = from[1], head = from[2] }, count, target :: any)
				assert(
					got.anchor == want[1] and got.head == want[2],
					`{target} on {string.format("%q", sample)} from ({from[1]}, {from[2]}) x{count}: got ({got.anchor}, {got.head}), want ({want[1]}, {want[2]})`
				)
			end
		end
	end)
end

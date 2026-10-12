local test = require("@greed/test")
local agent = require("@agent")

test("secrets in what a command printed are hidden before a model reads it", function()
	local text = table.concat({
		"AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP",
		"DB_PASSWORD=hunter2hunter2",
		'{"api_key": "abc123abc123", "name": "web"}',
		"Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
		"token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
		"-----BEGIN OPENSSH PRIVATE KEY-----",
		"b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
		"-----END OPENSSH PRIVATE KEY-----",
		"PATH=/usr/bin  name=web  sk-ok",
	}, "\n")
	local hidden, count = agent.redact(text)
	for _, secret in
		{
			"AKIAABCDEFGHIJKLMNOP",
			"hunter2",
			"abc123abc123",
			"abcdefghijklmnopqrstuvwxyz",
			"ghp_",
			"b3BlbnNz",
		}
	do
		assert(not string.find(hidden, secret, 1, true), `{secret} left in:\n{hidden}`)
	end
	assert(count == 6, `{count} hidden:\n{hidden}`)
	assert(string.find(hidden, "PATH=/usr/bin  name=web  sk-ok", 1, true), hidden)
	assert(string.find(hidden, '"name": "web"', 1, true), hidden)
	local wrapped = agent.untrusted("a test", "DB_PASSWORD=hunter2hunter2")
	assert(string.find(wrapped, ' hidden="1 secret">', 1, true), wrapped)
	assert(not string.find(wrapped, "hunter2", 1, true), wrapped)
end)

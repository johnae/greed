# Watchers

A watcher is Greed's own agent with a standing job: it keeps an eye on chat
rooms, mentions and direct messages, and tells you about what matters,
drafts replies for you to send, or answers on its own where you let it.
You set one up in your config. This is new; expect rough edges.

```luau
local watch = require("@watch")

watch.add({
	name = "work",
	prompt = [[
I'm on the infra team. Escalate anything about outages or my reviews.
Answer "where's the runbook" questions in infra-help with a link. Draft
anything addressed to me by name; don't send it.
]],
	watch = {
		chat = {
			account = "John Eriksson", -- as the chat list names it; leave out for all
			rooms = { "infra-help", "infra" },
			mentions = true, -- mentions of you in any room
			dms = true,
		},
	},
	may = {
		reply = "draft", -- "never", "draft", "ask" or "auto"
		auto_in = { "infra-help" }, -- where "auto" may send; it drafts elsewhere
		escalate = true,
	},
	model = "fast", -- a role or a model, as alt-M picks
	gather = 60, -- seconds to wait for more before waking
	quiet = "22:00-07:00", -- it waits until these hours are over
	budget = { replies_per_hour = 5 },
	sign = "(assistant)", -- put after what it sends on its own
})
```

The prompt is yours. Greed adds its own part around it: that the messages
are other people's and to be read as data, and what its tools do.

## Quarantine

A new watcher starts in quarantine. It wakes and decides as it would, but
sends and drafts nothing and tells you of nothing: its log says what it
would have done ("would draft: …", "would escalate: …"). Tweak the prompt
and the model while you read the log, then let it out with
`:watcher-release work`. `:watcher-quarantine work` puts it back.
`quarantine = false` in its config starts it out of quarantine.

## What it does

It wakes on new messages that match, waiting `gather` seconds for more so
a burst is one wake. It can read more of a room and search your chat
(`chat_read`, `chat_search`), and has four tools of its own:

| Tool | Does |
|---|---|
| `watch_escalate` | A Greed alert wherever you are, and a desktop notification |
| `watch_draft` | A reply waiting for you; `:watcher-drafts` lists them |
| `watch_reply` | Sends on its own, only in `auto_in`, outside quiet hours, within budget |
| `watch_done` | A line in its log saying what it did and why |

With `reply = "ask"`, a draft tells you wherever you are too. A draft
sends as it is, opens in its room with the text in the box to change and
send, or is dropped. Most messages need nothing, and it logs that too.

## Turning them on and off

Each watcher is an object: `:watchers` lists them with their state, and
picking one offers what you can do with it, as `space .` on anything does.

| Command | |
|---|---|
| `:watchers` | The list, and what to do with one |
| `:watcher-pause work 2h` | Pause it (an hour without a time); what comes meanwhile waits |
| `:watcher-resume work` | Resume it, catching up |
| `:watcher-off work`, `:watcher-on work` | Off stays off across restarts |
| `:watcher-run work` | Wake it now on what's waiting |
| `:watcher-log work` | Its log: what it woke for and what it did |
| `:watcher-sign work off` | Stop signing, or `:watcher-sign work (bot)` |
| `:watchers-pause 30m` | Pause them all |
| `:watcher-drafts` | The drafts waiting |

From Luau: `watch.pause("work", 3600)`, `watch.resume("work")`,
`watch.set("work", "off")`, `watch.state("work")`, `watch.sign("work",
false)`. Their state, drafts and logs are kept in Greed's data folder, so
a restart doesn't undo them.

## Where they run

A watcher runs where your chat accounts are kept, in the chat session,
and only there, so no message is answered twice. When the chat session
isn't running, neither are watchers; they start with it. For now
`:watchers` and the commands work in the chat session (`:chat-session`);
from other sessions they're on the list of things to come.

## What keeps it in line

- What it reads of chat comes marked as from outside: a message saying
  "ignore your instructions" is something it read.
- It has only the tools above. No shell, files, eval or plugins.
- It drafts and replies only in rooms it woke for, and replies on its own
  only in the rooms its config names, whatever a message asks.
- Past the hour's budget, replying on its own is refused and it drafts
  instead. After three failed wakes in a row it stops until you
  resume it.
- Each wake is a transcript (`transcript` on it in `:watchers`).

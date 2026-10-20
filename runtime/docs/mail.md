# Mail

Greed reads, searches and writes your mail. `greed mail` opens it in a
session of its own, on a full page: your inbox, newest first, with the
search box over it. What you type narrows the list as you type, in the
query language every search in Greed speaks:

```text
in:inbox is:unread                 unread in the inbox
from:anna invoice date:2w..        from Anna, about an invoice, the last two weeks
in:work -is:mine                   in the Work folder or label, not sent by you
account:work is:flagged            flagged, in the work account
subject:"quarterly report" is:attachment
```

## Setting it up

Mail needs two things: `greed-mail`, the program that syncs it, and a
`mail.toml` saying which accounts to sync.

`greed-mail` comes with Greed: Greed's packages put it beside `greed`, and
Greed finds it there (or on your `PATH`). If yours is somewhere else, say
where with `:set mail-program /path/to/greed-mail`.

`mail.toml` goes in Greed's config folder: `~/.config/greed/mail.toml`, or
under `$XDG_CONFIG_HOME` when that's set. One account looks like this:

```toml
[[account]]
name = "private"
address = "anna@example.com"
imap = { host = "imap.example.com" }
smtp = { host = "smtp.example.com" }
password = ["rbw", "get", "mail"]
```

`password` is a command that prints the password, here from Bitwarden;
`["pass", "show", "mail"]` or `["security", "find-generic-password", "-w",
"-s", "mail"]` work as well. It runs when a connection needs the password,
and the password is never written down. Each setting is explained under
[mail.toml](#mailtoml) below; Gmail and Proton have their own ways, shown
there too.

`greed-mail check` logs in to each account and says what its server can
do, which is a quick way to see that `mail.toml` is right. Then:

```sh
greed mail
```

The first sync brings the newest mail first, and the list fills in as it
goes; a message you open has its text fetched ahead of the rest. A big
mailbox takes a while the first time (on Proton through Bridge, each
message's text comes from Proton when first asked for). While it syncs,
a line over the list says how much of each account is in, and while it
indexes, a bar says how far it got. After that, new mail shows within
seconds.

### The mail session and the quick look

The mail session (`greed mail` from a shell, `:mail-session` from inside
Greed) is the mail client: it has the full page, and it's the one that
syncs, so keep it running for new mail to come in. Detach from it as from
any session; it goes on syncing.

In any other session, `:mail` opens a quick look: the same mail, in a
float over what you're working on (`q` closes it). It works as the page
does, and what you mark, archive, delete, write or answer there, the mail
session does for it. It needs the mail session running, and says so when
it isn't.

After an upgrade, the mail session indexes your mail again the first time
it starts (a minute or two for a hundred thousand messages); the list
shows how far it got, and fills in as it goes.

## Several accounts

Add an `[[account]]` for each, with a `name` of your choosing:

```toml
[[account]]
name = "private"
address = "anna@example.com"
imap = { host = "imap.example.com" }
smtp = { host = "smtp.example.com" }
password = ["rbw", "get", "private-mail"]

[[account]]
name = "work"
address = "anna.berg@company.example"
imap = { host = "mail.company.example" }
smtp = { host = "mail.company.example", tls = "starttls" }
password = ["rbw", "get", "work-mail"]

[[account]]
name = "gmail"
address = "anna.berg@gmail.com"
provider = "gmail"
password = ["rbw", "get", "gmail-app-password"]
```

They all sync into one place, so one list shows them all: `in:inbox` is
every account's inbox together, and a search finds mail in any of them.
`account:` narrows a search to one, by its `name`:

```text
account:work in:inbox              the work inbox
in:inbox -account:work             every inbox but work's
account:private from:anna          Anna's mail to your private address
```

For a tab for each, put them in your saved searches:

```luau
require("@mail").searches = {
	{ name = "All", query = "in:inbox" },
	{ name = "Private", query = "account:private in:inbox" },
	{ name = "Work", query = "account:work in:inbox" },
	{ name = "Gmail", query = "account:gmail in:inbox" },
}
```

You don't need tags to keep accounts apart: `account:` does that, for
mail old and new. Tags are for sorting within your mail, and they live on
each account's server, so a tag set on work mail stays with the work
account.

What you write goes through the account it's from. A reply is from the
address the mail was sent to, so a reply to work mail goes from work. New
mail (`c`) starts from your first account; change the `From:` line to
any other address of yours, and it goes through that account. Changes,
like archiving or deleting, happen in the account the message is in.

Rules see every account; add `account:` to a rule's query for one alone:

```luau
require("@mail").rules = {
	{ query = "account:work from:jira@company.example", tag = "jira", archive = true },
}
```

## The list

In the list, `enter` reads the thread under the cursor in its place, `/`
searches again and `$` syncs now; `q` in a thread goes back to the list.
Reading a thread marks it read.

A dot marks unread mail and ⚑ flagged mail; a message's folders, labels
and tags follow its subject (`#work`).

Over the list are your saved searches, each with how many unread messages
it finds, counted again as mail comes in. `g 1` to `g 9` go to them, and
`]` and `[` go to the next and the one before; pressing one goes to it
too. Set your own in your config:

```luau
require("@mail").searches = {
	{ name = "Inbox", query = "in:inbox" },
	{ name = "Work", query = "in:work is:unread" },
	{ name = "Recent", query = "date:2w.. -is:mine" },
	{ name = "Receipts", query = "(receipt OR invoice) is:attachment" },
}
```

A thread shows once, as its newest message the search found, with how
many it found after the subject (`(3)`). A change to a row changes those
messages and no others of the thread, so archiving a thread found in the
inbox leaves your replies in Sent. `:set mail-threads false` lists every
message on its own.

These work on the message under the cursor, or in a thread on all of it:

| Key      | Does                                                      |
| -------- | --------------------------------------------------------- |
| `u`      | marks it read, or unread when it's read                   |
| `s`      | flags it, or takes the flag off                           |
| `t`      | asks for a tag and puts it on, or takes it off if it's on |
| `T`      | makes a todo of it in your inbox note (see below)         |
| `b`      | opens it in a web browser, loading nothing from anywhere  |
| `e`      | moves it to the archive                                   |
| `d`, `#` | moves it to the trash; in the trash, asks, then deletes   |
| `r`      | replies to who sent it (in a thread, its last message)    |
| `a`      | replies to everyone it went to                            |
| `c`      | writes new mail                                           |
| `z`      | undoes the last change, or takes back mail just sent      |

A change shows at once and goes to the server within seconds. If the
server refuses it (a folder that went, say), it's taken back and Greed
says why. `z` undoes the last one, even once the server has it:
something archived goes back where it was, a mark comes off again.
Deleting from the trash is for good, so it asks first (`y` deletes).

## Reading

A thread opens on what's new: messages you've read before show as a line
each (who, when, how it starts) and open when you press them, and a quote
of four lines or more folds into one line saying how many, with the
"Anna wrote:" line over it; pressing it shows them. `o` shows all of the
thread at once, and folds it again.

Mail sent as HTML reads laid out in Greed: headings, bold and italics,
lists, tables of data (a receipt's lines) in columns, and tables only
there for layout as plain text. What the sender hid stays hidden, and
images show as their descriptions: nothing is fetched from anywhere, so
no tracking pixel tells the sender you read it. Links show as links;
`tab` goes from one to the next and `enter` opens it.

`h` reads the thread as its plain text instead (and back). `b`, in a
thread or the list, opens the message in your web browser as it was sent,
with everything that would load from elsewhere blocked: scripts, remote
images, fonts and styles.

What's attached is listed under who a message is from, with its kind and
size. `enter` on one opens it with what your system opens that kind of
file with; `S` saves it where you say (`~/Downloads` to start; the one
under the cursor, or the thread's only one). The mail session fetches it
from the server the first time, whole, and keeps it beside your mail for
next time. A file that's already where you save is never written over.

## Invites

A calendar invite reads as a card over the message: what it is, when in
your time zone, where, and who sent it.

```text
┌ Invite ──────────────────────────┐
│ Garden plans                     │
│ Friday 24 Oct 10:00 to 11:00     │
│ The shed                         │
│ From: Bob                        │
│  Accept   Maybe   Decline        │
└──────────────────────────────────┘
```

`enter` on Accept, Maybe or Decline sends your answer to whoever sent the
invite, the way calendars expect it, so it shows in theirs. It goes from
the address the invite was sent to, like any mail, with a copy in Sent. A
cancelled invite says so, and an answer to one of yours says who accepted
or declined.

## Writing

A reply opens with its header lines, the cursor on the line where your
text goes and the message you answer quoted under it:

```text
From: anna@example.com
To: Bob Lind <bob@example.com>
Cc:
Subject: Re: Invoice 41

Paid this morning.

On 2026-10-19 08:00, Bob Lind wrote:
> Please pay by Friday.
```

Edit it as any text, the header lines too (add `Bcc:` for blind copies,
addresses apart by commas). On `To:`, `Cc:` and `Bcc:` addresses complete
as you type, from the people you've had mail with, those you write to
most first; on `From:`, from your own addresses. `:mail-attach FILE`
attaches a file, on an `Attach:` line you can edit too (paths apart by
commas, 25 MB in all at most).

`:mail-send` sends it and goes back to the list; `:mail-close` drops it.
It waits ten seconds, in which `z` takes it back, then goes, and Greed
says when it's sent. A copy goes in your Sent folder (Gmail and Bridge
file it themselves), and the message you answered is marked answered.
Mail the server won't take stays out, and Greed says why.

## Tags

`in:work` (or `tag:work`) finds a message's folders, labels and tags.
Proton's labels and Gmail's come along as they are. `t` puts a tag on, or
takes it off, on the server, where your other mail apps see it too:

- On Gmail it's a Gmail label. Taking one off leaves the message where it
  is.
- On Proton it's a Proton label, one you've made in Proton already. It
  goes on as a copy of the message in the label's folder, and comes off
  by deleting it from there, which on Proton takes only the label off.
  It's off until the account in `mail.toml` says `labels = true`: try it
  on a message you can lose first.
- On other servers (Dovecot, Fastmail) it's an IMAP keyword.

## Todos

`T` asks for a todo about the message, starting as who sent it and what
it's about, and adds it to your inbox note in [Hoard](hoard.md). Say when
it's due in words, as anywhere in Hoard: `Bob Lind: Invoice 41 friday`.
It ends in a link back to the message:

```markdown
- [ ] Bob Lind: Invoice 41 [mail](mail:41@example.com) due:2026-10-23
```

Opening the link reads the thread again, in the mail session or as a
quick look anywhere else. The todo reads well without it too, on your
phone say.

## Rules

Rules act on new mail as it comes in: a query, and what to do with what
it finds. Set them in your config:

```luau
require("@mail").rules = {
	{ query = "from:github.com", tag = "github", archive = true },
	{ query = "from:boss@example.com", flag = true },
	{ query = "subject:newsletter", read = true },
}
```

A rule can mark what it finds `read`, `flag` it, put a `tag` on it, and
`archive` or `trash` it, in that order. Each rule looks at the new mail on
its own, so one that archives doesn't stop the next from tagging. Rules
run in the mail session, on mail that arrives once a mailbox is all
synced: what the first sync brings is left as it is.

## mail.toml

Each `[[account]]` has:

| Setting    | What it is                                                                 |
| ---------- | -------------------------------------------------------------------------- |
| `name`     | what you call it: `account:NAME` searches it                              |
| `address`  | its address; new mail is from it, and you log in as it                    |
| `password` | a command that prints the password                                        |
| `imap`     | where its mail is: `{ host, port, tls }`                                  |
| `smtp`     | where its mail is sent, with the same login                               |
| `user`     | who logs in, when it isn't the address                                     |
| `aliases`  | the other addresses it gets mail at and sends from                        |
| `provider` | `gmail` or `proton-bridge`, for their ways; leave it out for any other    |
| `labels`   | `true` lets `t` set Proton labels (see [Tags](#tags)); off without it     |

`tls` is `implicit` (the default: ports 993 for IMAP, 465 for SMTP),
`starttls` (ports 143 and 587), or `none` for a server on this machine
only. `port` is needed only when it isn't one of those.

`aliases` are you too: mail from them counts as yours (`is:mine`), a reply
or an invite's answer goes from the alias it was sent to, `From:` may name
any of them, and they're never offered as people to write to.

### Gmail

```toml
[[account]]
name = "gmail"
address = "anna.berg@gmail.com"
provider = "gmail"
password = ["rbw", "get", "gmail-app-password"]
```

Gmail needs no `imap` or `smtp`. Its password here is an app password
(made under your Google account's security settings, with two-step
verification on), not the one you sign in with. Gmail's labels are places
like folders: `in:receipts` finds what's labelled Receipts.

### Proton

Proton's mail comes through [Proton Mail Bridge](https://proton.me/mail/bridge),
which runs on your machine (or another you reach) and gives each account
an IMAP and an SMTP port and a password of its own:

```toml
[[account]]
name = "proton"
address = "anna@proton.me"
aliases = ["anna@pm.me", "hello@annaberg.example"]
provider = "proton-bridge"
imap = { host = "127.0.0.1", port = 1143, tls = "starttls" }
smtp = { host = "127.0.0.1", port = 1025, tls = "starttls" }
password = ["pass", "show", "mail/bridge"]
```

The ports, the password and whether it's `starttls` are the ones Bridge
shows for the account. List every address Proton lets you send from in
`aliases`. Proton's labels are places like folders, and folders under
Proton's `Folders/` show without it.

## How syncing works

`greed-mail` syncs your accounts into a store on this machine (in Greed's
data folder, `~/.local/share/greed/mail`) and keeps an index of
it that Greed searches, so searching never waits on a server. Changes you
make are made in the store at once and sent to the server in the next
round, within seconds.

Once everything is in, new mail shows within seconds: greed-mail waits on
each account's inbox for the server to say something arrived (IMAP IDLE),
and checks every two minutes on a server that can't. When an account
can't be reached it tries again a little later each time, up to every
five minutes. `greed-mail sync` syncs once, on its own, if you want to see
it work.

# Mail

`greed mail` opens your mail in a session of its own, on a full page. It
opens on your inbox, newest first, with the search box over it; what you
type narrows the list as you type it, in the query language every search
in Greed speaks:

```text
in:inbox is:unread                 unread in the inbox
from:anna invoice date:2w..        from Anna, about an invoice, the last two weeks
in:work -is:mine                   in the Work folder or label, not sent by you
subject:"quarterly report" is:attachment
```

In the list, `enter` reads the thread under the cursor in its place, `/`
searches again and `$` syncs now; `q` in a thread goes back to the list.
Reading a thread marks it read.

Over the list are your saved searches, each with how many unread
threads it finds, counted again as mail comes in. `g 1` to `g 9` go to
them, and `]` and `[` go to the next and the one before; pressing one
goes to it too. To keep your own, set them in your config:

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
| `b`      | opens it in a web browser, loading nothing from anywhere  |
| `e`      | moves it to the archive                                   |
| `d`, `#` | moves it to the trash; in the trash, deletes it for good  |
| `r`      | replies to who sent it (in a thread, its last message)    |
| `a`      | replies to everyone it went to                            |
| `c`      | writes new mail                                           |

A change shows at once and goes to the server within seconds. If the
server refuses it (a folder that went, say), it's taken back and Greed
says why.

## Reading

Mail sent as HTML reads laid out in Greed: headings, bold and italics,
lists, tables of data (a receipt's lines) in columns, and tables only
there for layout as plain text. What the sender hid stays hidden, and
images show as their descriptions: nothing is fetched from anywhere, so
no tracking pixel tells the sender you read it. Links show as links;
`tab` goes from one to the next and `enter` opens it.

In a thread, `h` reads it as its plain text instead (and back). `b`, in a
thread or the list, opens the message in your web browser as it was sent,
with everything that would load from elsewhere blocked: scripts, remote
images, fonts and styles.

What's attached is listed under who a message is from, with its kind and
size. `enter` on one opens it with what your system opens that kind of
file with; `S` saves it where you say (`~/Downloads` to start; the one
under the cursor, or the thread's only one). The mail session fetches it
from the server the first time, whole, and keeps it beside your mail for
next time. A file that's already where you save is never written over.

## Tags

A message's folders, labels and tags show after its subject (`#work`),
and `in:work` (or `tag:work`) finds them. Proton's labels and Gmail's come
along as they are. On other servers (Dovecot, Fastmail) `t` sets a tag as
an IMAP keyword, which every client of that mailbox sees. On Proton and
Gmail, setting tags from Greed isn't done yet: it says so and changes
nothing.

## Writing

A reply opens with its header lines, the cursor on the line where your
text goes and the message you answer quoted under it:

```text
To: Anna Berg <anna@example.com>
Cc:
Subject: Re: Invoice 41

Paid this morning.

On 2026-10-19 08:00, Anna Berg wrote:
> Please pay by Friday.
```

Edit it as any text, the header lines too (add `Bcc:` for blind copies,
addresses apart by commas), then `:mail-send` sends it and goes back to
the list; `:mail-close` drops it. It goes in the next sync round, within
seconds, and Greed says when it's sent. A copy goes in your Sent folder
(Gmail and Bridge file it themselves), and the message you answered is
marked answered. Mail the server won't take stays out, and Greed says
why.

The mail session is the one that syncs. In any other session, `:mail`
opens a quick look at the same mail in a float (`q` closes it), and
`:mail-session` goes to the mail session, starting it if it isn't
running. The quick look reads what the mail session has synced, and
changes nothing: a message whose text hasn't come in yet gets it once you
open it there, and marking, archiving, deleting and writing mail are done
there too.

## Accounts

A separate program, `greed-mail`, syncs your accounts into a store on
this machine and keeps an index of them that Greed searches. The mail
session starts it (the `mail-program` option names it, if it
isn't on your `PATH`). It reads the accounts from `mail.toml` in Greed's
config folder:

```toml
[[account]]
name = "proton"
address = "anna@proton.me"
provider = "proton-bridge"
imap = { host = "127.0.0.1", port = 1143, tls = "starttls" }
password = ["pass", "show", "mail/bridge"]

[[account]]
name = "work"
address = "anna@example.com"
imap = { host = "mail.example.com" }
smtp = { host = "mail.example.com", tls = "starttls" }
password = ["rbw", "get", "work-mail"]
```

`password` is a command that prints the password; it runs when a
connection needs it, and the password is never written down. `tls` is
`implicit` (the default, port 993), `starttls` (port 143), or `none` for
a server on this machine. `smtp` is where mail is sent, with the same
login, `tls` as for `imap` (ports 465 and 587); Gmail needs none, and for
Bridge it's Bridge's SMTP port. `provider` is `gmail` or `proton-bridge` for
their ways (Gmail needs no `imap`, and its labels and Bridge's are places
like folders); any other server is plain IMAP.

`greed-mail check` logs in to each account and says what its server can
do, and `greed-mail sync` syncs once, if you want to see it work on its
own.

The first sync brings the newest mail first: the list fills in as it
goes, and a message you open has its text fetched ahead of the rest. On
Proton through Bridge, each message's text comes from Proton the first
time it's asked for, which takes a while for a big mailbox; after that it
stays here.

Once everything is in, new mail shows within seconds: greed-mail waits
on each account's inbox for the server to say something arrived (IMAP
IDLE), and checks every two minutes on a server that can't. When an
account can't be reached it tries again a little later each time, up to
every five minutes.

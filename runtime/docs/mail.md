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
searches again and `r` syncs now; `q` in a thread goes back to the list.
Reading a thread marks it read.

These work on the message under the cursor, or in a thread on all of it:

| Key       | Does                                                    |
| --------- | ------------------------------------------------------- |
| `u`       | marks it read, or unread when it's read                 |
| `s`       | flags it, or takes the flag off                         |
| `e`       | moves it to the archive                                 |
| `d`, `#`  | moves it to the trash; in the trash, deletes it for good |

A change shows at once and goes to the server within seconds. If the
server refuses it (a folder that went, say), it's taken back and Greed
says why.

The mail session is the one that syncs. In any other session, `:mail`
opens a quick look at the same mail in a float (`q` closes it), and
`:mail-session` goes to the mail session, starting it if it isn't
running. The quick look reads what the mail session has synced, and
changes nothing: a message whose text hasn't come in yet gets it once you
open it there, and marking, archiving and deleting are done there too.

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
password = ["rbw", "get", "work-mail"]
```

`password` is a command that prints the password; it runs when a
connection needs it, and the password is never written down. `tls` is
`implicit` (the default, port 993), `starttls` (port 143), or `none` for
a server on this machine. `provider` is `gmail` or `proton-bridge` for
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

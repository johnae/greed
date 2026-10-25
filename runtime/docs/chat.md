# Chat

Matrix and Mattermost rooms in Greed, from any session. Your accounts stay
connected in a session of their own, the chat service's (`chat.service`),
which starts by itself when something needs it; `:chat` anywhere shows the
same rooms. This is experimental; what's there and what isn't is listed at
the end.

Nothing connects until you sign in to an account (`:chat-login`), and
chat doesn't start with Greed unless `services-at-start` names it
([Sessions](sessions.md#sessions-and-clients)).

[![The rooms in the sidebar, the garden club's messages, a message from Jonas answered with a quote of it above the answer, then every room searched for deploy and the message found opened in Ops](https://github.com/johnae/greed/releases/download/media/chat.png)](https://github.com/johnae/greed/releases/download/media/chat.mp4)

```sh
greed chat
```

`greed chat` goes to the chat service's session, which shows your rooms
and channels in a sidebar on the left, those that mention you first, then
those with something unread, then the most recent; a dot beside a direct
message says whether the other person is around (Mattermost). After them
come your Matrix spaces and Mattermost teams (`◆`), each with your rooms
in it under it. `enter` opens a room
beside the sidebar: its messages, laid out as Markdown and kept up to date
as they come, and a box under them, and `q` goes back to the sidebar. The
room is marked read as you look at it, who's writing shows under the
messages, and on Matrix "seen by" says who has read up to where.
`:chat-sidebar` shows the same sidebar in any other session.

| Key | In a room |
| --- | --- |
| `enter` (writing) | send what's in the box, as Markdown |
| `alt-enter` | a new line in the box |
| `alt-r` | answer the message under the cursor |
| `alt-t` | open its thread; what you send there goes in the thread |
| `alt-k` | react to it, or take your reaction back |
| `alt-e` | change it (your own); `enter` sends the change |
| `alt-d` | delete it, after asking |
| `alt-b`, `enter` | press one of its buttons, or pick from its menu (Mattermost) |
| `alt-/` | pick a command into the box (Mattermost) |
| `alt-up` | fetch older messages |
| `] m`, `[ m` | the next or previous message |
| `tab`, `shift-tab` | the next or previous room in the bar over a room (the rooms you opened); `alt-1`…`alt-9` one of them |
| `q`, `esc` | stop answering or changing; else back to the room, or to the list (the sidebar) |

`space .` on a message offers the same, and copying what it says.

Code blocks and tables in a message keep their lines, so a bot's
box-drawn table stays lined up. A wide one gets cut with `…` at the edge,
which isn't great, so `open as text` on `space .` puts the whole message
in a buffer of its own where you can scroll sideways.

A room shows each thread's first message with how many replies it has;
the replies are in the thread. A reply to a message (Matrix) gets a line
above it saying what it answers, like `↳ Bea: lunch at noon?`.

On Mattermost, a message starting with `/` runs a command, like `/away` or
an integration's; what it answers only you shows in the room. Posts from
integrations show their attachments' text, and their buttons and menus
under them.

A link's preview shows under its message: the site, the page's title, and a
line of what it says (see below for where they come from).

In any other session, `:chat` opens the same list in a floating view of
the tab, starting the chat service's session first if it isn't running.
Rooms open in it and `q` goes back to the list; `alt-f` hides it and shows
it again like the tab's other floats, and `:chat` brings it back showing
the rooms. In a room, `esc` then `q` goes back to them too.

## Signing in

`:chat-login` asks for the service and the server (`matrix.org`,
`mm.example.com`), then offers the ways that server has:

- **Password**, with the code from your authenticator app when your
  Mattermost account asks for one.
- **In the browser**: single sign-on, like a company's Keycloak behind
  Mattermost, or a Matrix server's own sign-in page (OAuth, as matrix.org
  has it). Greed opens the page; sign in there, and approve Greed if the
  server asks. The browser then comes back to Greed by itself where it
  can; where it can't (Greed over ssh, Mattermost's `mattermost://` link,
  a server that hands the sign-in back to a link of Greed's own), paste
  the link the browser ended on into the prompt, or let your system hand
  it over (below).

Your sign-in is kept in the system keyring (or Greed's secrets file
where there's none), never in a file of its own. `:chat-logout` signs out
and forgets it.

### Letting the browser hand links to Greed

`greed link URL` hands a link to the chat service, which finishes the
sign-in waiting for it, in whichever session you started it. On Linux,
Greed's packages install the desktop entry `greed-link.desktop`, which
does that for `mattermost://` links and Greed's own (`io.github.johnae:`).
Make it their handler once:

```sh
xdg-mime default greed-link.desktop x-scheme-handler/mattermost
xdg-mime default greed-link.desktop x-scheme-handler/io.github.johnae
```

From the tarball, unpacked into `~/.local`, run
`update-desktop-database ~/.local/share/applications` first. Without the
handler, or on macOS, paste the link the browser ends on when Greed asks.
Making `greed-link.desktop` the handler for `mattermost://` also takes
those links from Mattermost's own desktop app, if you have it.

## Encrypted rooms (Matrix)

Greed signs in as a device of its own, which needs your keys to read
encrypted rooms. The room list says when this device isn't verified yet.

- `:chat-recover` takes your recovery key (Element calls it a security
  key) and unlocks the keys kept on the server: older messages decrypt and
  this device counts as verified.
- `:chat-verify` asks your other devices (your phone, Element) to verify
  this one. Accept there, and Greed shows seven emoji to compare with what
  the other device shows; say whether they're the same.
- When another device asks to verify this one, Greed asks you to accept,
  then shows the emoji the same way.
- `:chat-encryption` says how an account stands. For an account with no
  recovery key yet it sets one up and shows it once: keep it somewhere
  safe, Greed doesn't keep it.

## Joining and leaving

`+` in the list (or `:chat-join`) offers the rooms you could join: on
Matrix the rooms your server lists publicly, on Mattermost your teams'
public channels you aren't in. Or pick "By its address or id" and type one,
like `#garden:example.org`. The room opens once you've joined.

A Matrix space is a list of rooms rather than a room to talk in. Join one
like any room (`+`, `#space:nixos.org`), and it shows in the list with
`◆`. `enter` on it offers the rooms it holds, `✓` before those you're in:
pick one to open it or join it, or a space inside it (`◆`) to see that
one's. Rooms on another server are joined through the servers the space
names, and joining one there can take a minute. A Mattermost team works
the same way: `enter` on it offers its public channels.

An invite shows in the list with `+` before it; `enter` on it asks: `y`
joins, `n` says no. `-` in the list (or `:chat-leave` in a room) leaves a
room after asking.

## Searching

`/` in the list (or `:chat-search`) searches the messages of every account;
`alt-s` in a room searches that room. What it finds comes newest first, and
the message you pick opens in its room, older messages fetched until it
shows.

It's the same search as mail's and your notes': words, and `from:bea`,
`in:plans` (a room), `before:2026-10-01`, `is:mine`, `is:direct`,
`"a phrase"`.

The chat service keeps every message it sees to search, on this machine,
in Greed's data folder: as they come, and each room's older ones fetched
in the background as an account comes in, back to `chat-search-days` (90
by default). Encrypted rooms are kept once their messages are decrypted
here.

```luau
greed.option.set("chat-search-days", 365)
```

## Alerts

A new message that mentions you, or any message in a direct message, alerts
you:

- the room shows as needing you in the chat service's status until you
  look at it in any session,
- you get one notification wherever you are: the hub tells the Greed
  window or terminal on each machine you're attached from, whichever
  session it shows, as it does when an agent waits for you.

A room you're looking at, in any session, doesn't alert. `:chat-alerted`
goes to the room of the latest alert.

`:set chat-alerts all` alerts of everything the service would notify you of
(on Matrix, what your push rules on the server notify of),
`:set chat-alerts off` of nothing. `:set chat-alerts-desktop true` sends
them to the desktop's own notifications too (`notify-send` on Linux,
`osascript` on macOS), for when no Greed is attached anywhere.

Only new messages alert: what came while Greed was away shows as unread
counts in the list.

## What isn't here, and what happens instead

| Thing | What Greed does |
| --- | --- |
| Voice and video calls | Greed shows a call starting; `enter` on it opens it in the service's own app or web client to join. Greed doesn't do calls itself. |
| Videos and recordings | Shown as files with their size. `enter` on a recording or voice message plays it in the background with `mpv` or `ffplay` where one is installed (again stops it), else opens it in your system's player; a video opens in your system's player. Videos with a small picture show it. |
| Pictures and stickers | Drawn in the room where the window or terminal can show images (Greed's window, kitty); elsewhere a line with the name. `enter` opens the picture in Greed. |
| Other files | `enter` fetches and opens it: a PDF or picture in Greed, the rest in the program your system opens it with. `:chat-attach PATH` sends one. |
| Link previews | The page's site, title and a line of what it says, under the message, as the server fetched it: Mattermost where the server has link previews on, Matrix where the server allows them. None in encrypted Matrix rooms, so the server doesn't learn their links. `:set chat-previews false` turns them off. No pictures from the pages. |
| Presence | Mattermost's dot beside a direct message. Matrix servers don't send it the way Greed syncs, so none there. |
| Read receipts | "seen by" on Matrix. Mattermost has none to show. |
| Polls | Matrix polls show their answers, votes and yours; `enter` votes for one (one answer a vote). Mattermost polls are made of buttons, which work as buttons. Making a poll isn't here. |
| Locations | A place shows its coordinates; `enter` opens it on OpenStreetMap in the browser. A live location is named as one, without where it is. |
| Mattermost Boards, Playbooks, and interactive dialogs a command or button opens | Not supported; open the message in the browser (`space .`) to use them. |
| Discord, Slack and others | Not supported. |

## The programs

Greed talks to each service through a program of its own,
`greed-matrix` and `greed-mattermost`, that keeps your accounts connected
and stores what Matrix needs locally (rooms, encryption keys, files it
fetched), locked with a key kept with your sign-in. They come with Greed:
its packages put them beside `greed`, and Greed starts them from there (or
your `PATH`); the `chat-matrix-program` and `chat-mattermost-program`
options name others. On another machine you reach with `greed ssh`, the
greed put there brings them along, so `greed chat` works there too.

# Chat

Matrix and Mattermost rooms in Greed, in a session of their own. This is
experimental; what's there and what isn't is listed at the end.

```sh
greed chat
```

The page lists your rooms and channels, those that mention you first,
then those with something unread, then the most recent; a dot beside a
direct message says whether the other person is around (Mattermost).
`enter` opens a room: its messages, laid out as Markdown and kept up to
date as they come, and a box under them. The room is marked read as you
look at it, who's writing shows under the messages, and on Matrix "seen
by" says who has read up to where.

| Key | In a room |
| --- | --- |
| `enter` (writing) | send what's in the box, as Markdown |
| `alt-enter` | a new line in the box |
| `alt-r` | answer the message under the cursor |
| `alt-t` | open its thread; what you send there goes in the thread |
| `alt-k` | react to it, or take your reaction back |
| `alt-e` | change it (your own); `enter` sends the change |
| `alt-d` | delete it, after asking |
| `alt-up` | fetch older messages |
| `q`, `esc` | stop answering or changing; else back to the room or the list |

`space .` on a message offers the same, and copying what it says.
A room shows each thread's first message with how many replies it has;
the replies are in the thread.

Outside the chat session, `:chat` opens the same list in a float.

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

`greed link URL` hands a link to the chat session, which finishes the
sign-in waiting for it. On Linux, the desktop entry `greed-link.desktop`
(in `dist/`) does that for `mattermost://` links and Greed's own
(`io.github.johnae:`); copy it to `~/.local/share/applications/` and make
it their handler:

```sh
xdg-mime default greed-link.desktop x-scheme-handler/mattermost
xdg-mime default greed-link.desktop x-scheme-handler/io.github.johnae
```

That takes `mattermost://` links from Mattermost's own desktop app, if
you have it. On macOS, paste the link.

## What isn't here, and what happens instead

| Thing | What Greed does |
| --- | --- |
| Voice and video calls | Greed shows a call starting; `enter` on it opens it in the service's own app or web client to join. Greed doesn't do calls itself. |
| Videos and recordings | Shown as files with their size; `enter` fetches one and opens it in your system's player. Videos with a small picture show it. Nothing plays inside Greed. |
| Pictures and stickers | Drawn in the room where the window or terminal can show images (Greed's window, kitty); elsewhere a line with the name. `enter` opens the picture in Greed. |
| Other files | `enter` fetches and opens it: a PDF or picture in Greed, the rest in the program your system opens it with. `:chat-attach PATH` sends one. |
| Links in messages | Shown in the text; no previews of the pages they lead to. |
| Encrypted Matrix rooms | Messages decrypt when this device has the keys. Verifying this device against another, and the recovery key that unlocks old messages, aren't here yet: until then, older messages may show as unreadable. |
| Presence | Mattermost's dot beside a direct message. Matrix servers don't send it the way Greed syncs, so none there. |
| Read receipts | "seen by" on Matrix. Mattermost has none to show. |
| Polls, locations, live locations | Shown as what they are, without voting or a map. |
| Mattermost slash commands, buttons in messages, Boards, Playbooks | Not yet; open the message in the browser (`space .`) to use them. |
| Spaces and teams | Listed with their rooms; no browsing a space's rooms you haven't joined, nor joining by address, yet. |
| Search | Not yet. |
| Notifications | Not yet: unread and mention counts show in the list, nothing pops up. |
| Discord, Slack and others | Not supported. |

## The programs

Greed talks to each service through a program of its own,
`greed-matrix` and `greed-mattermost`, that keeps your accounts connected
and stores what Matrix needs locally (rooms, encryption keys, files it
fetched), locked with a key kept with your sign-in. Greed starts them; the
`chat-matrix-program` and `chat-mattermost-program` options name others.

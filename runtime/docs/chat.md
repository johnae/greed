# Chat

Matrix and Mattermost rooms in Greed, in a session of their own. This is
experimental: rooms, messages, replies and sending work; reactions,
threads, files, encryption setup and the rest are still to come.

```sh
greed chat
```

The page lists your rooms and channels, those that mention you first,
then those with something unread, then the most recent. `enter` opens a
room: its messages, kept up to date as they come, and a box under them.

| Key | In a room |
| --- | --- |
| `enter` (writing) | send what's in the box, as Markdown |
| `alt-enter` | a new line in the box |
| `alt-r` | answer the message under the cursor |
| `alt-up` | fetch older messages |
| `q`, `esc` | back to the list |

Outside the chat session, `:chat` opens the same list in a float.

## Signing in

`:chat-login` asks for the service and the server (`matrix.org`,
`mm.example.com`), then offers the ways that server has:

- **Password**, with the code from your authenticator app when your
  Mattermost account asks for one.
- **In the browser**: single sign-on, like a company's Keycloak behind
  Mattermost, or a Matrix server's own sign-in page. Greed opens the
  page; once you're signed in there, the browser comes back to Greed by
  itself. Where it can't (Greed over ssh, or Mattermost's
  `mattermost://` link with nothing to open it), paste the link the
  browser ended on into the prompt.

Your sign-in is kept in the system keyring (or Greed's secrets file
where there's none), never in a file of its own. `:chat-logout` signs out
and forgets it.

## The programs

Greed talks to each service through a program of its own,
`greed-matrix` and `greed-mattermost`, that keeps your accounts connected
and stores what Matrix needs locally (rooms, encryption keys), locked with
a key kept with your sign-in. Greed starts them; the
`chat-matrix-program` and `chat-mattermost-program` options name others.

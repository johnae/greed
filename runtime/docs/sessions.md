# Sessions, machines and the hub

Greed keeps track of what runs in every session on every machine you use,
so the status line can say `◆ 1 waiting for you in api on eris` and one
key takes you there. This page explains how: sessions, the hub that
follows them on each machine, and how machines follow each other.

## Sessions and clients

A session is a Greed running in the background, normally one per project,
named after its folder. What you look at is a client attached to it: a
terminal, a window (`greed --gui`), or a terminal on another machine over
`greed ssh`. A client always attaches to one session.

```sh
greed ls          # the sessions on this machine
greed             # in a project: attach to its session, or start it
greed ssh eris    # a session on eris, shown here
```

Sessions are kept apart on purpose: a stuck plugin or a hungry language
server in one project leaves the others alone.

## The hub: one session follows the others

Each session wants to know what the others are doing: which agents wait
for you, which finished, what failed. Rather than every session watching
every other, one session on each machine does it for all of them: the
hub.

- The hub follows every other session on the machine and gathers what
  they report.
- The other sessions follow only the hub: each has one connection to it,
  rather than one to every other session.
- The hub decides what to tell you, so a waiting agent gives one desktop
  notification, not one per session. It remembers what it told you, so a
  restart doesn't tell you again.

The hub isn't a separate program. It's a role one of your sessions takes,
and every session works out which one by the same rule:

1. the session the `hub-session` option names, if it runs;
2. otherwise the first by name of the running sessions of the same greed
   build.

Every session looks at the running sessions every few seconds and applies
that rule, so they agree without asking each other. When the hub ends, the
next one by name becomes the hub within seconds. There's nothing to start
and nothing to set up.

Sessions of another build (say, after you rebuilt greed while they ran)
have a hub of their own until they're restarted.

To keep the hub in one place, for example a session you never quit:

```luau
greed.option.set("hub-session", "notes")
```

## Other machines

Once you've used `greed ssh eris`, this machine's hub follows the hub on
eris, and eris's agents show up here: on the status line, in `space i A`
(`:machine`), and in desktop notifications. `enter` on one opens that
session as `greed ssh eris` would.

| | |
|---|---|
| Follow a machine | `greed ssh HOST` once; it's followed for two weeks after you last did |
| Follow one you never ssh to | `greed.option.set("hub-hosts", "mini eris")` |
| Stop following one | `:machine-forget` |

Following uses your ssh keys or agent and never asks for a password or a
new host key. A machine that's off is tried again after a minute, then
less often, at most every half hour.

No hub is in charge. Each machine's hub follows the machines you point it
at, and what they know comes along: if your laptop follows eris and eris
follows mini, the laptop sees mini too. Each report says which machine
it's about, and the newest wins, so when two machines follow each other
nothing is counted twice: you still get one notification per waiting
agent.

## Over `greed ssh`

With `greed ssh eris`, your terminal talks straight to the session on
eris. Your own machine's hub isn't in between.

Two things connect the machines:

- Your terminal also asks your own machine's hub what's going on at home,
  and passes the answer to the session on eris. That's how `space i A` on
  eris lists your laptop's agents, and `enter` on one comes back. It's read
  only: nothing on your laptop can be done from eris through it.
- Separately, your laptop's hub follows eris's hub, so eris's agents show
  at home even when no terminal is open there.

## What the hub is used for

Agents waiting for you, notifications, and the list of agents across
sessions and machines ([Agents](agents.md#agents-in-your-other-sessions)
has the details).

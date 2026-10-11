# Boards

A board is a page of live shell commands, saved by name: pods that
aren't running, the disks filling up, the last deploys. Each command is a
card showing what it prints now, and cards go down the page, so a board
scrolls like any other buffer however many it has.

```text
ops

payments

◐ pods  every 5s · 1 changed · 14:05:02
  NAME                     READY   STATUS             RESTARTS   AGE
  worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   13         2h

◐ disk  every 60s · 0 changed · 14:05:00
  /dev/nvme0n1p2  468G  401G   44G  91% /
```

## Making one

`:board-new ops` makes a board in the project, at `.greed/boards/ops.md`,
and opens it; `:board-new! ops` makes one of your own, in `boards` under
your config folder, there in every project. On a board, `space a` asks for
a command and adds it as a card.

From a shell, once a command shows what you want, `space .` on its block
and "pin to board" adds it to a board you pick, or a new one. A watch is
pinned as a card running every so often (`watch -n 5 df -h` runs `df -h`
every five seconds), and a block that ran in another folder than the
project's root keeps it.

## The file

A board is Markdown, so it can go in git and be read anywhere. Its `#`
heading is its title, `##` headings are its sections, and every shell code
block is a card; the rest is there to read in the file and isn't shown:

````markdown
# ops

## payments

```sh every=5 title=pods
kubectl get pods -n payments | where STATUS != Running
```

```sh every=60 title=disk height=4
df -h /
```
````

After the language (`sh`, `bash`, `zsh`, `fish`, `nu` or `shell`):

- `every=SECONDS` runs it again that often; `live` alone is every two
  seconds. Without either it runs once, and again when the board does. A
  command that keeps printing, like `kubectl get pods -w`, stays live by
  itself.
- `title=NAME` names the card, which is its command otherwise.
- `height=LINES` is how many lines of it show (10); past that the card
  says how many more there are.
- `dir=PATH` runs it in another folder, from the project's root.

`space e` opens the file, and saving it shows the board as it says.

## Using one

`:board ops` opens a board, and `:board` alone picks one. Its cards run in
a shell of the board's own, out of sight, from the project's root, as
[watches](shell.md#watching-a-command) and other live blocks do, with the
same tables, filters and rows to act on.

| Key | What it does |
|---|---|
| `enter` | Open the card's block in a float, all of it, to filter and act on its rows |
| `space .` | Act on the card's block, as in a shell: change its command, filter, stop it |
| `space a` | Add a command as a card |
| `space e` | Open the board's file |
| `space r` | Run every card again |

A board stays open while you look at something else, and closing it stops
its cards.

## Boards from others

A board runs commands, so one you didn't make asks before it runs
anything, as [code blocks](using.md#runnable-code-blocks) in Markdown do:
`y` runs it this time, `a` always for that file. Trusting a file for one
trusts it for the other. Boards you make with `:board-new` or "pin to board" are trusted.

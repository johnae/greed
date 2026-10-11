# Boards

A board is a page of live shell commands, saved by name: pods that
aren't running, the disks filling up, the last deploys. Each command is a
card showing what it prints now. Cards sit side by side as far as the
window is wide and go on down the page, so a board scrolls like any other
buffer however many it has.

```text
ops

payments

◐ pods  every 5s · 1 changed · 14:05:02             ◐ disk  every 60s · 0 changed · 14:05:00
NAME                    READY   STATUS              Filesystem      Size  Used Avail Use%
worker-5c6b7d8f9-abcde  0/1     CrashLoopBackOff    /dev/nvme0n1p2  468G  401G   44G  91%
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
  itself. It's the board's own `watch`: the command needs none.
- `title=NAME` names the card, which is its command otherwise.
- `height=LINES` is how many lines of it show (10); past that the card
  says how many more there are.
- `span=COLUMNS` makes it as wide as that many cards side by side, and
  `wide` as wide as the board.
- `chart` draws it as a [chart](shell.md#charts) as big as the card;
  `chart="bar CPU"` says which. A command ending in `| chart` of its own
  is as big as the card too.
- `dir=PATH` runs it in another folder, from the project's root.

`space e` opens the file, and saving it shows the board as it says. Cards
that run what they ran before keep running as they were; only the ones
you changed start again.

Cards are at least `board-card-width` columns wide (50), so a window of
100 or more shows two side by side, and one of 150 three. Each section
starts a row of its own, and a row is as tall as its tallest card. What's
wider than a card is cut at its edge: `enter` shows all of it.

For the same layout in any window, give the board its number of columns
in front matter at the top of its file. With two, a card is half the
row, and `wide` (or `span=2`) the whole of it; a window too narrow for
two shows one.

````markdown
---
columns: 2
---
# machine

```sh every=2 chart wide height=12 title=load
cat /proc/loadavg
```

```sh every=5 chart=area height=8 title="memory, MiB"
free -m | awk '/Mem:/ { print $3 }'
```

```sh every=10 chart height=8 title="example.com, seconds"
curl -o /dev/null -s -w '%{time_total}\n' https://example.com
```
````

## Using one

`:board ops` opens a board, and `:board` alone picks one. Its cards run in
a shell of the board's own, out of sight, from the project's root, as
[watches](shell.md#watching-a-command) and other live blocks do, with the
same tables, filters and rows to act on.

| Key | What it does |
|---|---|
| `enter` | Open the card's block in a float, all of it, to filter and act on its rows |
| `space .` | Act on the card's block, as in a shell: change its command, filter, stop it |
| `<` `>` | Move the card back or on along the board, in its file too |
| `space a` | Add a command as a card |
| `space e`, or `i` `a` `c` `o` on a card | Open the board's file, at the card's command; saving it updates the board, and `ctrl-o` (`alt-left` in the vscode style) goes back to it |
| `space r` | Run every card again |

`<` and `>` work in every editing style, as a board can't be typed in.

A board stays open while you look at something else, and closing it stops
its cards.

## Live charts

A card with `chart` is drawn as a [chart](shell.md#charts), and one that
runs `every` so often adds a point each time, so the chart moves. Each
of these is a whole board; save one as `.greed/boards/NAME.md` and
`:board NAME`. The first is for Linux.

````markdown
# machine

## load

```sh every=2 chart title="load average" height=8
cat /proc/loadavg
```

```sh every=5 chart=area title="memory used, MiB" height=8
free -m | awk '/Mem:/ { print $3 }'
```

## disks and the web

```sh every=60 chart="bar Use%" title=disks height=4
df -h -x tmpfs -x devtmpfs
```

```sh every=10 chart title="example.com, seconds" height=4
curl -o /dev/null -s -w '%{time_total}\n' https://example.com
```
````

A cluster, with metrics-server running in it:

````markdown
# cluster

```sh every=10 chart title="CPU by pod" wide
kubectl top pods
```

```sh every=10 chart="bar MEMORY(bytes)" title="memory by pod"
kubectl top pods
```

```sh every=30 chart=bar title="restarts"
kubectl get pods --no-headers | awk '{ print $1, $4 }'
```
````

`kubectl top pods` charted every ten seconds is a line a pod, of its CPU,
in cores and millicores; with `bar MEMORY(bytes)` it's a bar a pod, as
it is now, in MiB and GiB. A card's chart is as wide as the card, and
`height` lines tall.

## Boards from others

A board runs commands, so one you didn't make asks before it runs
anything, as [code blocks](using.md#runnable-code-blocks) in Markdown do:
`y` runs it this time, `a` always for that file. Trusting a file for one
trusts it for the other. Boards you make with `:board-new` or "pin to board" are trusted.

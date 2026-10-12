# Charts

`| chart` turns any table into a chart: a command's output in the
[shell](shell.md), a `shell` block in a note, or a card on a
[board](boards.md). Run it again and again, with `watch` or `every=`, and
the chart follows the numbers as they change; a page of those is a
dashboard.

```text
❯ kubectl top pods | chart
api-7d9f8b6c5-2xkqz    ████████████▊ 0.25
worker-5c6b7d8f9-abcde ████████████████████████████████████████████ 1.2
redis-0                █▊ 0.035
```

In a terminal a chart is drawn in characters (braille for lines, eighth
blocks for bars) so it shows everywhere. In the window, and in terminals
that draw pictures (kitty, Ghostty, WezTerm, Konsole), it's drawn as a
picture with smooth lines; `:set scene-drawing cells` keeps characters.

## Kinds of chart

| Kind | Guessed when the table has | Ask for it with |
|---|---|---|
| Bars | A name column and numbers: a bar a row | `chart bar`, `chart bar CPU MEMORY` for two, `--stacked` to stack them |
| Lines | A time column and numbers, or numbers alone, or any table in a watch | `chart line`, `chart line rate over time` |
| Area | Never guessed | `chart area`, `--stacked` to stack the series |
| Dots | Two number columns and nothing to name the rows by | `chart scatter` (the first column across, the second up) |

The rest of what can follow `chart`:

| | |
|---|---|
| `COLUMN ...` | The number columns to chart, in place of the guess |
| `over COLUMN` | What runs along the bottom: a time column, or any number column |
| `by COLUMN` | What names the rows: bars, or with a time column a line for each name |
| `--log` | A log scale, for numbers that span powers of ten |
| `--last N` | In a watch, how many points each line keeps (120) |
| `--width N`, `--height N` | Its size in cells; it's as wide as the view, `chart-height` (12) tall |
| `--why` | Say how each column was read and why it chose the chart it did |

Column names match without minding case, spaces or marks, so `by
mounted_on` is df's `Mounted on`; the rest of a name has to be there, as
in `MEMORY(bytes)`.

## How it reads a table

`chart --why` shows its reasoning, a line a column:

```text
❯ kubectl top pods | chart --why
NAME           names, for the rows
CPU(cores)     numbers, in cores, charted
MEMORY(bytes)  numbers, in bytes, left out

bar: CPU(cores) by NAME: api-7d9f8b6c5-2xkqz 250m, worker-5c6b7d8f9-abcde 1.2, +1 more
because the rows have names (NAME): a bar each, of CPU(cores)
```

- The first text column names the rows. With a name column, only the
  first number column is charted, as CPU and memory on one scale would
  hide the CPU; name the columns to chart more.
- A column of dates and times (ISO 8601, or numbers in a column called
  `time`, `date`, `timestamp` or `ts`) runs along the bottom.
- Columns of ids (`PID`, `user_id`) and durations (`AGE`) are left out:
  they aren't measurements. Name one to chart it anyway.
- Numbers keep their units: `128Mi` and `1.5Gi` are bytes, kubectl's
  `250m` is cores, `45%` a percent. Bars of two columns in different
  units are each scaled to their own greatest.
- Text that isn't a table, like `cat /proc/loadavg`, is read as words, a
  column each; a first line without numbers is its header.
- JSON (`kubectl get pods -o json`, `docker ps --format json`, `nu -c
  '... | to json'`) is a table of its fields. CSV and TSV need `from csv`
  or `from tsv` in front: `cat samples.csv | from csv | chart`.

## Over time

There are three ways to get a chart over time.

Running it again, in a watch or a block or card with `every=SECONDS`,
each run adds a point to every line, so the chart is of how the numbers
went. Each row becomes a line, named by its name column:

```text
❯ watch -n 2 kubectl top pods | chart
```

draws a line a pod, of its CPU, over the last 120 runs. A table of one
row, like the load average, gets a line a number column instead. Rows
with the same name in one run add up to one point, so a program with ten
processes is one line of their total.

A table with a time column is drawn along it, a line a number
column. When a name column's names come again, as in samples of
several hosts, it's a line for each name, or say which column with `by`:

```text
❯ cat samples.csv | from csv | chart cpu by host
```

```csv
time,host,cpu
2026-10-12T07:26:40Z,web,20
2026-10-12T07:26:40Z,db,50
2026-10-12T07:27:40Z,web,27
2026-10-12T07:27:40Z,db,53
```

From Prometheus over a range: `prom QUERY --range 3h` gives a row a time
and a column a series, a line each (see below).

## A line for each thing

Lines are the dimensions you split by. A few that work as written:

```text
❯ watch -n 2 kubectl top pods | chart                 a line a pod, of its CPU
❯ watch -n 2 kubectl top pods | chart MEMORY(bytes)   of its memory
❯ watch -n 2 kubectl top nodes | chart                a line a node
❯ watch -n 2 ps -A -o pcpu= -o ucomm= | sort -rn | head -n 8 | chart
                                                      a line a program, of its CPU
❯ cat samples.csv | from csv | chart cpu by host      a line a host
❯ prom 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))' --range 3h | chart
                                                      a line a machine
```

A chart has at most eight lines: the eight greatest now, as `top` would
show them, each keeping its colour while it stays. Lines that drop out
come back when they're among the greatest again. To choose what's shown,
narrow the table first: `head -n 8`, `where`, or `sum by` in PromQL.

## Prometheus

`prom QUERY` asks a Prometheus server, or anything that answers its query
API, like VictoriaMetrics and Thanos. It asks `prometheus-url`
(`http://localhost:9090` unless you set it) or `--url`. Each series is a
row, named by its labels' values:

```text
❯ prom 'sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})' | chart
hyperspool     ███████████████████████████████████████████ 1.88
kube-system    ████████████████████████████████████▎ 1.58
flux-system    ████████████▋ 0.55
monitoring     ███████▏ 0.31
```

Queries that chart well:

| Query | What it shows |
|---|---|
| `sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})` | CPU requested, a bar a namespace |
| `count by (phase) (kube_pod_status_phase == 1)` | Pods by phase: how many run, wait, fail |
| `sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))` with `--range 3h` | Busy CPUs per machine, the last three hours |
| `max by (instance) (node_load1)` | The load of each machine |
| `sum by (job) (rate(http_requests_total[5m]))` | Requests a second, per job |
| `histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` with `--range 1h` | The 99th percentile latency over the hour |

`--range DURATION` (`30m`, `3h`, `2d`) asks for that long up to now, and
`--step` sets the time between points (about 120 points unless said).

Use `sum by (...)` to keep a query to a few series with short names: a
series is named by all its labels' values, joined with `/`, and only
eight lines show.

For a live chart, run it again: `watch -n 15 prom 'QUERY' | chart` in the
shell, or `every=15` on a card. Each run adds a point. For a longer view
right away, `--range` draws what Prometheus already has.

## Dashboards

A [board](boards.md) is a Markdown file of commands, each a card. A card
with `chart` after its language is drawn as a chart as big as the card,
and `every=SECONDS` runs it again so the chart moves. This one is for a
cluster with kube-state-metrics:

````markdown
---
columns: 2
---
# cluster

```shell every=15 chart wide height=10 title="busy CPUs per machine"
prom 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))'
```

```shell every=60 chart=bar title="CPU requested by namespace"
prom 'sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})'
```

```shell every=30 chart=bar title="pods by phase"
prom 'count by (phase) (kube_pod_status_phase == 1)'
```
````

The same works in any note: a `shell` block with `every=5` and a line
ending in `| chart` keeps its chart up to date where it is, until
`space m s` stops it.

## Boards for Linux and macOS

Many commands print differently on the two, or take other flags: `free`
is Linux's, `ps -o comm` is a cut-off path on a Mac, `df -h` says `Use%`
on Linux and `Capacity` on a Mac. A board meant for both can use the
forms both agree on. This one works as it is on both:

````markdown
---
columns: 2
---
# machine

```shell every=2 chart wide height=8 title="load average"
uptime | awk -F'load averages?: ' '{ gsub(",", "", $2); print "load1 load5 load15"; print $2 }'
```

```shell every=2 chart height=10 title="CPU % by program"
ps -A -o pcpu= -o ucomm= | sort -rn | head -n 8
```

```shell every=30 chart="bar Capacity by mounted_on" height=10 title="disks"
df -kP | where Filesystem ~ /dev/
```

```shell every=60 chart=bar height=8 title="this folder, KiB"
du -sk * | sort -rn | head -n 8
```

```shell every=5 chart=area height=8 title="memory used, MiB"
case "$(uname)" in Darwin) vm_stat | awk -v page="$(pagesize)" '/Pages active/ { a = $3 } /Pages wired/ { w = $4 } END { print "used"; print int((a + w) * page / 1048576) }' ;; *) free -m | awk '/Mem:/ { print "used"; print $3 }' ;; esac
```
````

What makes it work on both:

- POSIX forms. `df -kP` prints the same columns on both, `Capacity`
  included. `ps -A -o pcpu= -o ucomm=` gives each process's CPU and its
  program's name, number first, as Mac program names can have spaces.
  `du -sk` is in KiB on both.
- `case "$(uname)"` for what has no common form, like memory: one
  line, a branch for `Darwin` and one for the rest. A card runs a line at
  a time, so the whole `case` goes on one line.
- nu. Where [nu](https://www.nushell.sh) is installed, its `ps`, `ls`,
  `du` and `sys` give the same tables on every system, with full names.
  Hand them over as JSON, which the shell reads as a table:

```shell every=2 chart title="CPU % by program"
nu -c 'ps | select name cpu | sort-by cpu --reverse | first 8 | to json'
```

## Pitfalls

- `ps`'s `%CPU` differs. On Linux it's the average over the process's
  whole life, so a long-running program's line hardly moves; on a Mac
  it's a recent average. nu's `ps` measures it now on both.
- A header that looks like numbers isn't one. `1m 5m 15m` reads as
  numbers (`1m` is kubectl's millicores), so the first row becomes data.
  Name columns with words: `load1 load5 load15`.
- Names that come back add up. In a watch, rows of the same name are
  summed, which is right for processes of one program but not for two
  different things that share a name. Make the names unique first.
- Eight lines at most. The rest aren't drawn; narrow the table so the
  ones you care about are among the eight.
- The history is in memory. A watch's or card's points are kept while
  it runs. Changing its command or what follows `chart` starts over, and
  so does closing the board.
- Commands that read your whole home folder (`du -sk ~/*`) on a Mac
  ask for access to Music, Photos and iCloud folders, and take long.
  Point them at the folders you mean.
- `--log` needs numbers above zero. Zeros and negatives have no place
  on a log scale and are left off.
- A chart that won't draw says why, naming the columns it found.
  `--why` tells what it made of each.

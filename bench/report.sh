#!/bin/sh
# Prints how benchmark runs went: each task, then each label (model and way
# of editing) in sum.
#
#   bench/report.sh [RESULTS.jsonl ...]   (all of bench/results by default)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 0 ]; then
	set -- "$here"/results/*.jsonl
fi

cat "$@" | jq -rs '
  def pct(a; b): if b > 0 then (100 * a / b | floor | tostring) + "%" else "-" end;
  def k(n): if n >= 1000000 then (n / 100000 | floor / 10 | tostring) + "M"
            elif n >= 1000 then (n / 100 | floor / 10 | tostring) + "k" else (n | tostring) end;
  (["label", "task", "pass", "secs", "calls", "first change", "errors", "input", "cached", "out", "edits ok"] | @tsv),
  (.[] | [.label, .task + (if .rep > 1 then " #" + (.rep | tostring) else "" end),
          (if .passed then "yes" elif .timed_out then "timeout" else "no" end),
          (.seconds // 0), (.calls // 0), (.before_change // 0), (.tool_errors // 0),
          k(.input // 0), pct(.cached // 0; .input // 0), k(.output // 0),
          "\(.edits_ok // 0)/\((.edits_ok // 0) + (.edits_failed // 0))"] | @tsv),
  "",
  (["label", "runs", "passed", "secs/run", "calls/run", "first change", "input/run", "cached", "edits ok"] | @tsv),
  (group_by(.label)[] | . as $runs | length as $n |
    [.[0].label, $n, pct(map(select(.passed)) | length; $n),
     (map(.seconds // 0) | add / $n | floor), (map(.calls // 0) | add / $n | floor),
     (map(.before_change // 0) | add / $n | floor),
     k(map(.input // 0) | add / $n), pct(map(.cached // 0) | add; map(.input // 0) | add),
     "\(map(.edits_ok // 0) | add)/\(map((.edits_ok // 0) + (.edits_failed // 0)) | add)"] | @tsv)
' | column -t -s "$(printf '\t')"

#!/bin/sh
# Runs the agent benchmark with Greed's own agent, headless, in a profile of
# its own, and prints how it went.
#
#   bench/run.sh [--provider P] [--model M] [--edits replace|hashline]
#                [--tasks fix-bug,rename] [--repeat N] [--label NAME]
#                [--url http://host:11434/v1 --context 32768]   (a server like Ollama elsewhere)
#                [--solutions]   (each task's solution.luau in place of the agent, to test the checks)
#
# Keys come from your usual state folder (GREED_STATE_DIR, or
# ~/.local/state/greed), or ANTHROPIC_API_KEY and the like.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
greed=${GREED:-$repo/target/release/greed}
provider=anthropic
model=claude-sonnet-5
edits=replace
tasks=""
repeats=1
label=""
url=""
context=0
solutions=false
while [ $# -gt 0 ]; do
	case $1 in
	--provider) provider=$2; shift 2 ;;
	--model) model=$2; shift 2 ;;
	--edits) edits=$2; shift 2 ;;
	--tasks) tasks=$2; shift 2 ;;
	--repeat) repeats=$2; shift 2 ;;
	--label) label=$2; shift 2 ;;
	--url) url=$2; shift 2 ;;
	--context) context=$2; shift 2 ;;
	--solutions) solutions=true; shift ;;
	*) echo "bench/run.sh: unknown argument $1" >&2; exit 2 ;;
	esac
done
if [ -z "$tasks" ]; then
	tasks=$(cd "$here/tasks" && ls | paste -sd, -)
fi
stamp=$(date +%Y%m%d-%H%M%S)
label=${label:-$model-$edits}
# On disk (a /tmp in memory fills with the builds), and short, since session
# sockets live under it.
work=${BENCH_WORK:-$repo/target/b}/$stamp
profile=$work/p
mkdir -p "$profile/config" "$here/results"
: >"$profile/config/init.luau"
results=$here/results/$stamp.jsonl

# A copy of Greed's own plugins with the runner among them, so it loads as
# one of them (links wouldn't do: plugins are trusted by where they really are).
cp -R "$repo/runtime" "$work/runtime"
cp -R "$here/runner" "$work/runtime/plugins/bench-runner"

json_tasks=$(printf '%s' "$tasks" | sed 's/[^,][^,]*/"&"/g')
cat >"$profile/config/bench.json" <<EOF
{
  "tasks_dir": "$here/tasks",
  "tasks": [$json_tasks],
  "work": "$work",
  "results": "$results",
  "done": "$work/done",
  "label": "$label",
  "repeats": $repeats,
  "url": "$url",
  "solutions": $solutions,
  "role": { "provider": "$provider", "model": "$model", "edits": "$edits", "context": $context }
}
EOF

export GREED_PROFILE="$profile"
export GREED_STATE_DIR="${GREED_STATE_DIR:-$HOME/.local/state/greed}"
export GREED_RUNTIME="$work/runtime"
(cd "$work" && exec "$greed" serve >"$work/serve.log" 2>&1) &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
echo "results: $results"
while [ ! -e "$work/done" ]; do
	if ! kill -0 $server 2>/dev/null; then
		echo "bench/run.sh: the session ended early; see $work/serve.log" >&2
		exit 1
	fi
	sleep 5
done
"$greed" ctl quit --force >/dev/null 2>&1 || true
if [ -s "$work/done" ]; then echo "bench/run.sh: $(cat "$work/done")" >&2; fi
"$here/report.sh" "$results"

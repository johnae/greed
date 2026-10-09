A benchmark for Greed's own agent: small coding tasks with a check that
decides pass or fail, run headless, with numbers on how each went.

```sh
cargo build --release
bench/run.sh --model claude-haiku-4-5-20251001 --label haiku-replace
bench/run.sh --model claude-haiku-4-5-20251001 --edits hashline --label haiku-hashline
bench/report.sh                       # every run so far, side by side
```

```text
label           task         pass  secs  calls  first change  errors  input   cached  out   edits ok
haiku-replace   fix-bug      yes   20    17     2             4       107.8k  90%     1.7k  1/2
...
label           runs  passed  secs/run  calls/run  first change  input/run  cached  edits ok
haiku-replace   8     75%     31        19         6             98.2k      89%     9/11
```

Each task is a folder in `tasks/`: `project/` is copied to a folder of its
own for each run, `task.json` has the `prompt`, and a `check` (a shell
command run in that folder, with `$TASK_DIR` the task's folder) or a
`luau_check` (Luau run in the editor that returns `true`), and how many
seconds it may take (`timeout_s`). The code tasks are Rust crates without
dependencies, checked with `cargo test --offline`.

`run.sh` starts `greed serve` in a profile of its own under `$TMPDIR`, with
the runner (`runner/`) loaded among Greed's own plugins. For each task the
runner starts a fresh session of Greed's agent, allows what it asks to do,
installs plugins it asks to install, cancels its questions (no one is
there to answer), then runs the check. Each run is a line of JSON in
`results/STAMP.jsonl`, and its conversation is kept in `results/STAMP/`.

What a line holds: `passed`, `timed_out`, `seconds`, `turns`, `calls` and
`by_tool`, `before_change` (calls before the first edit, write, try, eval
or command), `tool_errors`, `asked` (questions it tried to ask),
`requests`, `input`, `cached` and `output` tokens, and `edits_ok` and
`edits_failed`.

Options: `--provider`, `--model`, `--edits replace|hashline`,
`--tasks fix-bug,rename`, `--repeat N` (the tasks N times, for how much a
model varies), `--label NAME`. Keys come from your usual state folder
(`GREED_STATE_DIR`, or `~/.local/state/greed`), or from variables like
`ANTHROPIC_API_KEY`. Runs use real models and cost what they use.

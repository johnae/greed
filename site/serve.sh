#!/usr/bin/env bash
# Shows greed.rs at http://localhost:8000 (or $PORT) as you change it: the
# docs rebuild when a page changes, and the front page is served from site/
# as it is. Needs mdbook and miniserve.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/target/site
port=${PORT:-8000}

"$root/site/build.sh"
# The front page from the source, so a reload shows an edit.
for file in index.html style.css assets; do
  rm -rf "${out:?}/$file"
  ln -s "$root/site/$file" "$out/$file"
done

mdbook watch "$root/docs" --dest-dir "$out/docs" &
watcher=$!
trap 'kill $watcher' EXIT
miniserve "$out" --index index.html --port "$port" --interfaces 127.0.0.1

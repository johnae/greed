#!/usr/bin/env bash
# Builds greed.rs into target/site: the front page, and the docs with their
# reference pages generated from the editor itself, as it is with no config.
# Needs mdbook. `site/serve.sh` builds it and shows it at localhost.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/target/site

cargo build -q -p greed-editor --manifest-path "$root/Cargo.toml"

# An editor with only the default plugins: no config, and nothing it keeps
# written anywhere but here.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
XDG_CONFIG_HOME=$scratch/config XDG_STATE_HOME=$scratch/state \
  XDG_DATA_HOME=$scratch/data XDG_CACHE_HOME=$scratch/cache \
  GREED_CONFIG_DIR=$scratch/config/greed \
  "$root/target/debug/greed" reference "$root/docs/reference"

rm -rf "$out"
mkdir -p "$out"
mdbook build "$root/docs" --dest-dir "$out/docs"
cp "$root/site/index.html" "$root/site/style.css" "$out/"
cp -r "$root/site/assets" "$out/"
echo "greed.rs" > "$out/CNAME"
echo "built $out"

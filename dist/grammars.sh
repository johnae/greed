#!/usr/bin/env bash
# Builds the grammars in dist/grammars.txt as WebAssembly into a folder,
# each with Helix's highlights and injections for it (what they inherit
# put first), plus SHA256SUMS. The grammars workflow runs it and
# publishes the folder as a release, which the languages plugin
# downloads from:
#
#   dist/grammars.sh target/grammars
#
# Needs git, curl and the tree-sitter CLI, which downloads the wasi-sdk
# it builds with the first time. That wasi-sdk doesn't run on NixOS;
# point TREE_SITTER_WASI_SDK_PATH at one that does.
set -euo pipefail
shopt -s inherit_errexit

helix=ba40e547426b0f9896c8bdc699a4ab11f2b37dbc
list=$(cd "$(dirname "$0")" && pwd)/grammars.txt
mkdir -p "${1:?usage: dist/grammars.sh OUT}"
out=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/helix"

# Prints Helix's `kind` queries for `lang`, the ones it inherits first;
# nothing if it has none of that kind.
queries() {
  local lang=$1 kind=$2
  local file="$work/helix/$lang.$kind.scm"
  if [ ! -e "$file" ]; then
    local url="https://raw.githubusercontent.com/helix-editor/helix/$helix/runtime/queries/$lang/$kind.scm"
    local status
    status=$(curl -sSL -o "$file" -w '%{http_code}' "$url")
    case $status in
      200) ;;
      404) : >"$file" ;;
      *) echo "downloading $url: status $status" >&2 && return 1 ;;
    esac
  fi
  local parent
  for parent in $(sed -n 's/^; inherits: *//p' "$file" | head -n1 | tr ',' ' '); do
    queries "$parent" "$kind"
  done
  cat "$file"
}

while read -r name repo rev lang; do
  case $name in '' | '#'*) continue ;; esac
  echo "$name"
  src="$work/$name"
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "https://github.com/$repo" "$rev"
  git -C "$src" checkout -q FETCH_HEAD
  tree-sitter build --wasm -o "$out/$name.wasm" "$src"
  for kind in highlights injections; do
    text=$(queries "$lang" "$kind")
    if [ -n "$text" ]; then
      printf '%s\n' "$text" >"$out/$name.$kind.scm"
    fi
  done
done <"$list"

cd "$out"
sha256sum -- *.wasm *.scm >SHA256SUMS

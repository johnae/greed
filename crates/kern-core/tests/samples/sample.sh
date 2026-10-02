#!/usr/bin/env bash
# Build it
set -euo pipefail

build() {
  local target="${1:-all}"
  if [[ -f Makefile ]]; then
    make -j4 "$target" 2>&1 | tee build.log
  fi
}

for dir in src tests; do
  echo "building $dir: $(date)"
done
build release

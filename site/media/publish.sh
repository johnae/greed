#!/usr/bin/env bash
# Uploads what record.sh made, target/media/*/*.{mp4,png}, to the `media`
# release on GitHub, where the docs and greed.rs link to them, replacing
# files of the same name. Made the first time, as a pre-release, so the
# latest release stays the newest Greed. Needs gh, logged in.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
shopt -s nullglob
files=("$root"/target/media/*/*.mp4 "$root"/target/media/*/*.png)
if [ ${#files[@]} -eq 0 ]; then
  echo "nothing in target/media: run site/media/record.sh first" >&2
  exit 1
fi
if ! gh release view media >/dev/null 2>&1; then
  gh release create media --prerelease --latest=false --title "Media" \
    --notes "Videos and screenshots for the docs and greed.rs, recorded with site/media/record.sh."
fi
gh release upload media --clobber "${files[@]}"
echo "uploaded ${#files[@]} files to https://github.com/johnae/greed/releases/tag/media"

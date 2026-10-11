#!/usr/bin/env bash
# Records the demos, site/media/*.demo, as the window draws them, into
# target/media/NAME: NAME.mp4 when ffmpeg is here, the screenshots the demo
# takes, and its frames. `site/media/record.sh shell` records one. Needs a
# GPU, or software Vulkan like Mesa's lavapipe.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
media=$root/site/media
cargo build -q -p greed-editor --manifest-path "$root/Cargo.toml"

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  for demo in "$media"/*.demo; do
    names+=("$(basename "$demo" .demo)")
  done
fi

for name in "${names[@]}"; do
  # A fresh Greed in a folder of its own: the demo profile's config, and
  # the sample files to work on.
  # Under /tmp, away from anything a folder above would load into the
  # shell, as a project's environment.
  scratch=$(mktemp -d -p /tmp greed-demo.XXXXXX)
  cp -r "$media/profile" "$scratch/profile"
  cp -r "$media/work" "$scratch/work"
  cp "$media/$name.demo" "$scratch/"
  echo "recording $name"
  (cd "$scratch/work" && "$root/target/debug/greed" --profile "$scratch/profile" \
    --record "$scratch/$name.demo")
  out=$root/target/media/$name
  rm -rf "$out"
  mkdir -p "$(dirname "$out")"
  mv "$scratch/$name" "$out"
  rm -rf "$scratch"
  if command -v ffmpeg >/dev/null; then
    fps=$(awk '$1 == "fps" { print $2 }' "$media/$name.demo")
    ffmpeg -y -loglevel error -framerate "${fps:-30}" -i "$out/frames/%05d.png" \
      -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "$out/$name.mp4"
    echo "  $out/$name.mp4"
  else
    echo "  frames in $out/frames (no ffmpeg to make a video)"
  fi
done

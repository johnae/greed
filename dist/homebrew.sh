#!/usr/bin/env bash
# Writes the Homebrew formula and cask for a release into a checkout of the
# tap (johnae/homebrew-greed), from the release's SHA256SUMS:
#
#   dist/homebrew.sh 0.2.0 SHA256SUMS ../homebrew-greed
#
# The formula installs the greed binary from the release tarballs (macOS
# universal, Linux x86_64 and aarch64); the cask installs Greed.app.
set -euo pipefail

version=$1
sums=$2
tap=$3
url=https://github.com/johnae/greed/releases/download/v$version

sum() {
  local hash
  hash=$(awk -v file="greed-$version-$1" '$2 == file { print $1 }' "$sums")
  if [ -z "$hash" ]; then
    echo "no checksum for greed-$version-$1 in $sums" >&2
    exit 1
  fi
  echo "$hash"
}

mkdir -p "$tap/Formula" "$tap/Casks"

cat >"$tap/Formula/greed.rb" <<EOF
class Greed < Formula
  desc "Fast, extensible modal editor with agents as first-class clients"
  homepage "https://github.com/johnae/greed"
  license "MPL-2.0"

  if OS.mac?
    url "$url/greed-$version-macos-universal.tar.gz"
    sha256 "$(sum macos-universal.tar.gz)"
  elsif Hardware::CPU.arm?
    url "$url/greed-$version-linux-aarch64.tar.gz"
    sha256 "$(sum linux-aarch64.tar.gz)"
  else
    url "$url/greed-$version-linux-x86_64.tar.gz"
    sha256 "$(sum linux-x86_64.tar.gz)"
  end

  def install
    bin.install "bin/greed", "bin/greed-mail"
    share.install Dir["share/*"] if OS.linux?
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/greed --version")
  end
end
EOF

cat >"$tap/Casks/greed-app.rb" <<EOF
cask "greed-app" do
  version "$version"
  sha256 "$(sum macos.zip)"

  url "$url/greed-#{version}-macos.zip"
  name "Greed"
  desc "Fast, extensible modal editor with agents as first-class clients"
  homepage "https://github.com/johnae/greed"

  depends_on macos: ">= :big_sur"

  app "Greed.app"
end
EOF

echo "$tap/Formula/greed.rb and $tap/Casks/greed-app.rb for $version"

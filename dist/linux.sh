#!/usr/bin/env bash
# Builds the Linux release: greed with the window, for any distribution
# with glibc 2.28 or newer (Debian 10, Ubuntu 20.04, Fedora, Arch, RHEL 8
# and later). It runs in the manylinux_2_28 image, whose old glibc is what
# makes the binary run on the newer ones:
#
#   docker run --rm -v "$PWD:/src" -w /src \
#     quay.io/pypa/manylinux_2_28_$(uname -m) dist/linux.sh
#
# The window's libraries (Wayland or X11, xkbcommon, Vulkan or GL) are
# loaded when it opens, from the system, so the binary links only glibc and
# the C++ runtime. The tarball lands in target/packages.
set -euo pipefail

arch=$(uname -m)
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
name=greed-$version-linux-$arch

if ! command -v cargo >/dev/null; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
# The toolchain file's extra components are for working on Greed.
export RUSTUP_TOOLCHAIN=stable
# The C++ runtime goes in the binary: Luau is C++, and a distribution's
# libstdc++ may be older than the one it's built with.
export CXXSTDLIB=static=stdc++
cxx_lib=$(dirname "$(g++ -print-file-name=libstdc++.a)")
export RUSTFLAGS="${RUSTFLAGS:-} -L native=$cxx_lib"

# Greed, and beside it the programs its sessions run: greed-mail for mail,
# greed-matrix and greed-mattermost for chat.
cargo build --locked --profile dist -p greed-editor -p greed-mail -p greed-matrix -p greed-mattermost
bins="target/dist/greed target/dist/greed-mail target/dist/greed-matrix target/dist/greed-mattermost"

# Only glibc's own libraries and libgcc_s, and nothing newer than glibc 2.28.
allowed='^(libc|libm|libdl|libpthread|librt|libutil|libgcc_s|ld-linux-(x86-64|aarch64))\.so'
newest=GLIBC_2.0
for bin in $bins; do
  for lib in $(readelf -d "$bin" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    if ! [[ $lib =~ $allowed ]]; then
      echo "$(basename "$bin") links $lib, which not every distribution has" >&2
      exit 1
    fi
  done
  newest=$(
    { echo "$newest"; objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*'; } | sort -uV | tail -n1
  )
done
if [ "$(printf '%s\nGLIBC_2.28\n' "$newest" | sort -V | tail -n1)" != GLIBC_2.28 ]; then
  echo "greed needs $newest, newer than glibc 2.28" >&2
  exit 1
fi

# Laid out like /usr/local, so it unpacks into ~/.local or /usr/local.
out=target/packages/$name
rm -rf "$out"
mkdir -p "$out/bin" "$out/share/applications" "$out/share/icons/hicolor/256x256/apps"
# shellcheck disable=SC2086
cp $bins "$out/bin/"
# greed-link.desktop hands the browser's sign-in links back to greed's chat.
cp dist/greed.desktop dist/greed-link.desktop "$out/share/applications/"
cp site/assets/icon-256.png "$out/share/icons/hicolor/256x256/apps/greed.png"
cp LICENSE README.md THIRD-PARTY.md "$out/"
tar -C target/packages -czf "target/packages/$name.tar.gz" "$name"
echo "target/packages/$name.tar.gz (needs $newest)"

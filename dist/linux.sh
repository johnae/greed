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

cargo build --locked --profile dist -p greed-editor
bin=target/dist/greed

# Only glibc's own libraries and libgcc_s, and nothing newer than glibc 2.28.
allowed='^(libc|libm|libdl|libpthread|librt|libutil|libgcc_s|ld-linux-(x86-64|aarch64))\.so'
for lib in $(readelf -d "$bin" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
  if ! [[ $lib =~ $allowed ]]; then
    echo "greed links $lib, which not every distribution has" >&2
    exit 1
  fi
done
newest=$(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n1)
if [ "$(printf '%s\nGLIBC_2.28\n' "$newest" | sort -V | tail -n1)" != GLIBC_2.28 ]; then
  echo "greed needs $newest, newer than glibc 2.28" >&2
  exit 1
fi

# Laid out like /usr/local, so it unpacks into ~/.local or /usr/local.
out=target/packages/$name
rm -rf "$out"
mkdir -p "$out/bin" "$out/share/applications" "$out/share/icons/hicolor/256x256/apps"
cp "$bin" "$out/bin/"
cp dist/greed.desktop "$out/share/applications/"
cp site/assets/icon-256.png "$out/share/icons/hicolor/256x256/apps/greed.png"
cp LICENSE README.md THIRD-PARTY.md "$out/"
tar -C target/packages -czf "target/packages/$name.tar.gz" "$name"
echo "target/packages/$name.tar.gz (needs $newest)"

#!/usr/bin/env bash
# Builds the macOS release on a Mac: one binary for Apple silicon and Intel,
# as Greed.app (zipped; it opens the window) and on its own (a tarball, for
# the terminal and Homebrew). Both land in target/packages.
#
# With a Developer ID certificate in the keychain, named by
# GREED_SIGN_IDENTITY, both are signed with it, and with an App Store
# Connect API key (GREED_NOTARY_KEY, the .p8 file, GREED_NOTARY_KEY_ID and
# GREED_NOTARY_ISSUER) notarized, so they open without warnings. Without
# them they're signed ad hoc: they run, but a browser download has to be
# allowed in System Settings first.
set -euo pipefail

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
identity=${GREED_SIGN_IDENTITY:--}
out=target/packages
export MACOSX_DEPLOYMENT_TARGET=11.0
# The toolchain file's extra components are for working on Greed.
export RUSTUP_TOOLCHAIN=stable

rustup target add aarch64-apple-darwin x86_64-apple-darwin
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --locked --profile dist -p greed-editor --target "$target"
done
rm -rf "$out"
mkdir -p "$out"
lipo -create -output "$out/greed" \
  target/aarch64-apple-darwin/dist/greed target/x86_64-apple-darwin/dist/greed

app=$out/Greed.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/greed" "$app/Contents/MacOS/greed"
iconset=$out/greed.iconset
mkdir -p "$iconset"
# Each size iconutil wants, by the name it wants it under.
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256; do
  size=${spec%%:*}
  sips -z "$size" "$size" site/assets/icon-256.png --out "$iconset/icon_${spec#*:}.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/greed.icns"
rm -rf "$iconset"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Greed</string>
	<key>CFBundleDisplayName</key><string>Greed</string>
	<key>CFBundleIdentifier</key><string>rs.greed.Greed</string>
	<key>CFBundleExecutable</key><string>greed</string>
	<key>CFBundleIconFile</key><string>greed</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>$MACOSX_DEPLOYMENT_TARGET</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

sign() {
  if [ "$identity" = - ]; then
    codesign --force --sign - "$1"
  else
    codesign --force --timestamp --options runtime \
      --entitlements dist/entitlements.plist --sign "$identity" "$1"
  fi
}
sign "$out/greed"
sign "$app"

if [ "$identity" != - ] && [ -n "${GREED_NOTARY_KEY:-}" ]; then
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  zip -qj "$out/notarize.zip" "$out/greed"
  key=(--key "$GREED_NOTARY_KEY" --key-id "$GREED_NOTARY_KEY_ID" --issuer "$GREED_NOTARY_ISSUER")
  id=$(xcrun notarytool submit "$out/notarize.zip" "${key[@]}" --output-format plist |
    plutil -extract id raw -)
  echo "notarizing: submission $id"
  # Asked every 30 seconds for up to three hours: the first submissions of a
  # team can take Apple an hour or more, and a moment without the network
  # isn't the end of it.
  status="In Progress"
  for _ in $(seq 360); do
    status=$(xcrun notarytool info "$id" "${key[@]}" --output-format plist 2>/dev/null |
      plutil -extract status raw - 2>/dev/null) || status="In Progress"
    [ "$status" = "In Progress" ] || break
    sleep 30
  done
  echo "notarizing: $status"
  if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" "${key[@]}" || true
    exit 1
  fi
  # The app carries its ticket; the bare binary's is looked up online.
  xcrun stapler staple "$app"
  rm "$out/notarize.zip"
fi

ditto -c -k --keepParent "$app" "$out/greed-$version-macos.zip"
name=greed-$version-macos-universal
mkdir -p "$out/$name/bin"
cp "$out/greed" "$out/$name/bin/"
cp LICENSE README.md THIRD-PARTY.md "$out/$name/"
tar -C "$out" -czf "$out/$name.tar.gz" "$name"
echo "$out/greed-$version-macos.zip and $out/$name.tar.gz"

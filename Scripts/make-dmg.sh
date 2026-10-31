#!/bin/zsh
# Builds an ad hoc signed KAFFIN.dmg. It is not notarized, so other Macs must allow it by hand.
# Each commit gets its own version, so two DMGs can always be told apart.
set -euo pipefail

root=${0:A:h:h}
build=$root/build/dmg
rm -rf "$build"

number=$(git -C "$root" rev-list --count HEAD)
version=0.1.$number

# A mounted older DMG would otherwise be what Finder keeps showing.
for mount in /Volumes/KAFFIN*(N); do hdiutil detach -quiet "$mount" || true; done
rm -f "$root"/build/KAFFIN-*.dmg

xcodebuild -project "$root/KAFFIN.xcodeproj" -scheme KAFFIN -configuration Release \
  -derivedDataPath "$build/derived" -quiet \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$number" build

app=$build/derived/Build/Products/Release/KAFFIN.app
codesign --verify --deep --strict "$app"

mkdir "$build/stage"
ditto "$app" "$build/stage/KAFFIN.app"
ln -s /Applications "$build/stage/Applications"

dmg=$root/build/KAFFIN-$version.dmg
hdiutil create -quiet -ov -fs APFS -format UDZO -volname "KAFFIN $version" -srcfolder "$build/stage" "$dmg"
hdiutil verify -quiet "$dmg"
echo "$dmg"

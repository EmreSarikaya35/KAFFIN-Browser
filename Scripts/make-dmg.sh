#!/bin/zsh
# Builds an ad hoc signed KAFFIN.dmg. It is not notarized, so other Macs must allow it by hand.
set -euo pipefail

root=${0:A:h:h}
build=$root/build/dmg
rm -rf "$build"

xcodebuild -project "$root/KAFFIN.xcodeproj" -scheme KAFFIN -configuration Release \
  -derivedDataPath "$build/derived" -quiet build

app=$build/derived/Build/Products/Release/KAFFIN.app
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")

mkdir "$build/stage"
ditto "$app" "$build/stage/KAFFIN.app"
ln -s /Applications "$build/stage/Applications"

dmg=$root/build/KAFFIN-$version.dmg
hdiutil create -quiet -ov -fs APFS -format UDZO -volname KAFFIN -srcfolder "$build/stage" "$dmg"
hdiutil verify -quiet "$dmg"
echo "$dmg"

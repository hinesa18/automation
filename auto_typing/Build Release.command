#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
version="${AUTOTYPE_VERSION:-1.0.0}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print 'Use a numeric x.y.z version.'; exit 1; }
output="$PWD/dist"
work="$(mktemp -d /private/tmp/AutoType-release.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
app="$work/image/AutoType.app"
mkdir -p "$app/Contents/MacOS" "$output"
for arch in arm64 x86_64; do
    print "Building $arch…"
    xcrun swiftc -O -target "$arch-apple-macosx13.0" AutoType.swift \
        -o "$work/AutoType-$arch" -framework Cocoa \
        -framework ApplicationServices -framework Carbon -framework Vision
done
xcrun lipo -create "$work/AutoType-arm64" "$work/AutoType-x86_64" \
    -output "$app/Contents/MacOS/AutoType"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AutoType</string>
<key>CFBundleIdentifier</key><string>local.autotype.utility</string>
<key>CFBundleName</key><string>AutoType</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>AutoType detects your typed trigger and types your selected text.</string>
</dict></plist>
PLIST
xattr -cr "$app"
# Ad-hoc signing permits a friend build without exporting local certificates.
# Set a Developer ID Application identity for a future notarized release.
codesign --force --sign "${AUTOTYPE_RELEASE_IDENTITY:--}" --options runtime "$app"
codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/AutoType" -verify_arch arm64 x86_64
"$app/Contents/MacOS/AutoType" --self-test
cp 'Install AutoType.txt' "$work/image/Install AutoType.txt"
ln -s /Applications "$work/image/Applications"
hdiutil create -volname AutoType -srcfolder "$work/image" -ov -format UDZO \
    "$output/AutoType-$version-macOS-universal.dmg"
mkdir -p "$work/source/AutoType"
cp AutoType.swift README.md 'Start AutoType.command' 'Build Release.command' \
    'Install AutoType.txt' "$work/source/AutoType/"
ditto -c -k --keepParent "$work/source/AutoType" "$output/AutoType-$version-source.zip"
(cd "$output"; shasum -a 256 "AutoType-$version-macOS-universal.dmg" \
    "AutoType-$version-source.zip" > "AutoType-$version-SHA256SUMS.txt")
print "Release files: $output"

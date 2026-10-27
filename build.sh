#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/build/Usage Rings.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -framework AppKit -framework Security -framework LocalAuthentication Sources/main.swift -o "$APP/Contents/MacOS/UsageRings"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageRings</string>
<key>CFBundleIdentifier</key><string>local.akhil.usagerings</string>
<key>CFBundleName</key><string>Usage Rings</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>1.0.4</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
print "Built: $APP"

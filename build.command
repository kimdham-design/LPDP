#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/.build/LPDP.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Turntable"
cp ./*.png "$APP/Contents/Resources/Turntable/"
swiftc main.swift -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/LPDP" -framework Cocoa -framework AVFoundation -O
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
print "빌드 완료: $APP"

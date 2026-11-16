#!/bin/bash
# Archive Search — construit « Archive Search.app » (SwiftUI natif) avec les seuls Command Line Tools.
#   bash macos/build_app.sh            → macos/build/Archive Search.app
#   bash macos/build_app.sh --install  → copie aussi dans ~/Applications
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Archive Search.app"
VERSION="2.1.0"

echo "▸ compilation release"
# Binaire universel : Apple Silicon + Intel
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --package-path "$HERE" "${ARCHS[@]}" --product ArchiveSearch
BIN="$(swift build -c release --package-path "$HERE" "${ARCHS[@]}" --show-bin-path)/ArchiveSearch"

echo "▸ auto-test du cœur"
swift build -c release --package-path "$HERE" --product archive-check >/dev/null
"$(swift build -c release --package-path "$HERE" --show-bin-path)/archive-check" | tail -1

echo "▸ bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ArchiveSearch"

echo "▸ icône"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swiftc -O "$HERE/scripts/make_icon.swift" -o "$BUILD/make_icon" 2>/dev/null
"$BUILD/make_icon" "$BUILD/icon_1024.png" >/dev/null
for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Archive Search</string>
    <key>CFBundleDisplayName</key><string>Archive Search</string>
    <key>CFBundleExecutable</key><string>ArchiveSearch</string>
    <key>CFBundleIdentifier</key><string>com.robotariis.archive-search</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Robōtariis · Dark Umbrae</string>
</dict>
</plist>
PLIST

echo "▸ signature ad-hoc"
codesign --force --deep --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Archive Search.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "✓ installé : ~/Applications/Archive Search.app"
fi
echo "✓ $APP"

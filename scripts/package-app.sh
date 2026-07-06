#!/bin/zsh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$repo_root/dist"
app="$dist/CameraToolkit.app"
contents="$app/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"

cd "$repo_root"
swift build -c release --product CameraToolkit

rm -rf "$app"
mkdir -p "$macos" "$resources"
cp ".build/release/CameraToolkit" "$macos/CameraToolkit"
"$repo_root/scripts/make-app-icon.swift" "$resources/AppIcon.icns"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CameraToolkit</string>
  <key>CFBundleIdentifier</key>
  <string>org.cameratoolkit.CameraToolkit</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Camera Toolkit</string>
  <key>CFBundleDisplayName</key>
  <string>Camera Toolkit</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.photography</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$contents/PkgInfo"

echo "Built $app"

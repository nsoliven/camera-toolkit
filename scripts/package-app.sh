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
  <key>CFBundleName</key>
  <string>Camera Toolkit</string>
  <key>CFBundleDisplayName</key>
  <string>Camera Toolkit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $app"

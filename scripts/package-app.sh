#!/bin/zsh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$repo_root/dist"
app="$dist/CameraToolkit.app"
install_root="${CAMERA_TOOLKIT_INSTALL_DIR:-/Applications}"
installed_app="$install_root/CameraToolkit.app"
saved_state="$HOME/Library/Saved Application State/org.cameratoolkit.CameraToolkit.savedState"
old_window_key="NSWindow Frame SwiftUI.ModifiedContent<CameraToolkitApp.AppShell, SwiftUI._FlexFrameLayout>-1-AppWindow-1"
old_split_key="NSSplitView Subview Frames SwiftUI.ModifiedContent<CameraToolkitApp.AppShell, SwiftUI._FlexFrameLayout>-1-AppWindow-1, SidebarNavigationSplitView"
contents="$app/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"

cd "$repo_root"
swift build -c release --product CameraToolkit

if pgrep -x CameraToolkit >/dev/null 2>&1; then
  /usr/bin/osascript -e 'tell application id "org.cameratoolkit.CameraToolkit" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x CameraToolkit >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x CameraToolkit >/dev/null 2>&1; then
    pkill -x CameraToolkit || true
    sleep 0.5
  fi
fi

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
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$contents/PkgInfo"

echo "Built $app"

mkdir -p "$install_root"
rm -rf "$installed_app"
ditto "$app" "$installed_app"
echo "Installed $installed_app"

if [[ -d "$saved_state" ]]; then
  rm -rf "$saved_state"
  echo "Cleared saved window state $saved_state"
fi

if /usr/bin/defaults delete org.cameratoolkit.CameraToolkit "$old_window_key" 2>/dev/null; then
  echo "Cleared old CameraToolkit window frame preference"
fi

if /usr/bin/defaults delete org.cameratoolkit.CameraToolkit "$old_split_key" 2>/dev/null; then
  echo "Cleared old CameraToolkit split-view preference"
fi

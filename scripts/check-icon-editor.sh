#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/IconEditorChecks.noindex"
mkdir -p "$check_directory"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library -emit-module -module-name VideoQuickCore Sources/VideoQuickCore/*.swift -o "$check_directory/libVideoQuickCore.dylib" -emit-module-path "$check_directory/VideoQuickCore.swiftmodule" > "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -I "$check_directory" -L "$check_directory" -lVideoQuickCore -Xlinker -rpath -Xlinker "$check_directory" Sources/VideoQuickApp/EditorDocument.swift Sources/VideoQuickApp/EditorWindowSizing.swift Sources/VideoQuickApp/EditorWindowChrome.swift Sources/VideoQuickApp/EditorScrubWindow.swift Sources/VideoQuickApp/NativeCropPlayer.swift Sources/VideoQuickApp/TimelineScrollRegion.swift Sources/VideoQuickApp/ClipTimelineView.swift Sources/VideoQuickApp/Editor.swift Sources/VideoQuickApp/EditorWindowController.swift Tests/NativeIconEditorChecks.swift -o "$check_directory/IconEditorChecks" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun actool Sources/VideoQuickApp/ToolbarAssets.xcassets --compile "$check_directory" --platform macosx --minimum-deployment-target 14.0 --target-device mac --output-partial-info-plist "$check_directory/asset-info.plist" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
cp Resources/ThirdParty/Feather-LICENSE.txt "$check_directory/Feather-LICENSE.txt"
ffmpeg_bin="${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=s=640x360:d=12:r=25' -f lavfi -i 'sine=frequency=440:duration=12' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$check_directory/audio.mov"
"$ffmpeg_bin" -hide_banner -loglevel error -y -i "$check_directory/audio.mov" -an -c:v copy "$check_directory/silent.mov"
preview_app="$check_directory/IconEditorChecks.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
cp "$check_directory/IconEditorChecks" "$preview_app/Contents/MacOS/IconEditorChecks"
cp "$check_directory/Assets.car" "$check_directory/Feather-LICENSE.txt" "$preview_app/Contents/Resources/"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.volodyatoxic.VideoQuick.IconEditorChecks</string>
<key>CFBundleName</key><string>IconEditorChecks</string>
<key>CFBundleExecutable</key><string>IconEditorChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
"$preview_app/Contents/MacOS/IconEditorChecks" "$check_directory/audio.mov" "$check_directory/silent.mov" "$check_directory"

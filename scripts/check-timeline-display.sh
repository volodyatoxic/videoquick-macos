#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/TimelineDisplayChecks.noindex"
mkdir -p "$check_directory"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library -emit-module -module-name VideoQuickCore Sources/VideoQuickCore/*.swift -o "$check_directory/libVideoQuickCore.dylib" -emit-module-path "$check_directory/VideoQuickCore.swiftmodule" > "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -I "$check_directory" -L "$check_directory" -lVideoQuickCore -Xlinker -rpath -Xlinker "$check_directory" Sources/VideoQuickApp/EditorDocument.swift Sources/VideoQuickApp/EditorWindowChrome.swift Sources/VideoQuickApp/EditorScrubWindow.swift Sources/VideoQuickApp/TimelineScrollRegion.swift Sources/VideoQuickApp/ClipTimelineView.swift Tests/NativeTimelineDisplayChecks.swift -o "$check_directory/TimelineDisplayChecks" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
"${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=s=640x360:d=12:r=30' -c:v libx264 -pix_fmt yuv420p "$check_directory/fixture.mov"
"$check_directory/TimelineDisplayChecks" "$check_directory/fixture.mov" "$check_directory"

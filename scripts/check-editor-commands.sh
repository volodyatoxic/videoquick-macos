#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/EditorCommandChecks.noindex"
mkdir -p "$check_directory"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library -emit-module -module-name VideoQuickCore Sources/VideoQuickCore/*.swift -o "$check_directory/libVideoQuickCore.dylib" -emit-module-path "$check_directory/VideoQuickCore.swiftmodule" > "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -I "$check_directory" -L "$check_directory" -lVideoQuickCore -Xlinker -rpath -Xlinker "$check_directory" Sources/VideoQuickApp/EditorDocument.swift Sources/VideoQuickApp/EditorWindowChrome.swift Sources/VideoQuickApp/EditorScrubWindow.swift Sources/VideoQuickApp/NativeCropPlayer.swift Tests/NativeEditorCommandChecks.swift -o "$check_directory/EditorCommandChecks" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
"${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -y -f lavfi -i 'color=c=red:s=320x180:d=12:r=25' -c:v libx264 -pix_fmt yuv420p "$check_directory/fixture.mov"
"${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -y -i "$check_directory/fixture.mov" -f lavfi -i sine=frequency=440:duration=12 -c:v copy -c:a aac -t 12 -timecode 01:02:03:04 "$check_directory/camera.mov"
"$check_directory/EditorCommandChecks" "$check_directory/fixture.mov" "$check_directory/camera.mov" "$@"
